/**
    Implementation of pointer to static/GC data `GlobalPtr`.

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   Adam Búš
*/
module btl.autoptr.global_ptr;

import btl.traits.common;

import btl.internal.traits;

import btl.autoptr.common;


/**
    Check if type `T` is `isGlobalPtr`.
*/
public template isGlobalPtr(T){
    import std.traits : isInstanceOf;

    enum bool isGlobalPtr = isInstanceOf!(GlobalPtr, T);
}

/**

*/
public template GlobalPtr(_Type){
    import std.traits : CopyTypeQualifiers, Unqual, isDynamicArray;

    enum bool referenceElementType = isClassOrInterface!_Type || isDynamicArray!_Type;

    struct GlobalPtr{
        /**
            Type of element managed by `RcPtr`.
        */
        public alias ElementType = _Type;


        /**
            Same as `ElementType*` or `ElementType` if is class/interface/slice.
        */
        public alias ElementReferenceType = ElementReferenceTypeImpl!ElementType;



        /**
            Constructs a `GlobalPtr` without managed object. Same as `GlobalPtr.init`

            Examples:
                --------------------
                GlobalPtr!long x = null;

                assert(x == null);
                assert(x == GlobalPtr!long.init);
                --------------------
        */
        public this(typeof(null) nil)scope pure nothrow @safe @nogc{
        }



        /**
            Constructs a `GlobalPtr` without managed object. Same as `GlobalPtr.init`

            Examples:
                --------------------
                {
                    GlobalPtr!long x = new long(42);

                    assert(x != null);
                    assert(x.get == 42);
                }

                {
                    static const long i = 42;
                    GlobalPtr!(const long) x = &i;

                    assert(x != null);
                    assert(x.get == 42);
                }
                --------------------
        */
        public this(ElementReferenceType elm)scope pure nothrow @safe @nogc{
            this._element = elm;
        }

        /// ditto
        public this(const ElementReferenceType elm)scope const pure nothrow @safe @nogc{
            this._element = elm;
        }

        /// ditto
        public this(immutable ElementReferenceType elm)scope immutable pure nothrow @safe @nogc{
            this._element = elm;
        }

        /// ditto
        public this(shared ElementReferenceType elm)scope shared pure nothrow @safe @nogc{
            this._element = elm;
        }

        /// ditto
        public this(const shared ElementReferenceType elm)scope const shared pure nothrow @safe @nogc{
            this._element = elm;
        }



        /**
            Forward constructor (merge move and copy constructor).
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs)@trusted pure nothrow @nogc
        if(isGlobalPtr!Rhs
            && isConstructable!(Rhs, This)
            && !is(Rhs == shared)
            && !isMoveCtor!(This, rhs)
        ){
            this._element = rhs._element;
        }

        public this(Rhs, this This)(scope auto ref Rhs rhs, Forward fw)@trusted pure nothrow @nogc
        if(isGlobalPtr!Rhs
            && isConstructable!(Rhs, This)
            && !is(Rhs == shared)
        ){
            this._element = rhs._element;
        }

        //copy ctors:
        static if(isCopyConstructable!(typeof(this), typeof(this)))
            this(ref scope typeof(this) rhs)@safe{this(rhs, Forward.init);}
        else
            @disable this(ref scope typeof(this) rhs)@safe;

        static if(isCopyConstructable!(typeof(this), const typeof(this)))
            this(ref scope typeof(this) rhs)const @safe{this(rhs, Forward.init);}
        else
            @disable this(ref scope typeof(this) rhs)const @safe;

        static if(isCopyConstructable!(typeof(this), immutable typeof(this)))
            this(ref scope typeof(this) rhs)immutable @safe{this(rhs, Forward.init);}
        else
            @disable this(ref scope typeof(this) rhs)immutable @safe;

        static if(isCopyConstructable!(typeof(this), shared typeof(this)))
            this(ref scope typeof(this) rhs)shared @safe{this(rhs, Forward.init);}
        else
            @disable this(ref scope typeof(this) rhs)shared @safe;

        static if(isCopyConstructable!(typeof(this), const shared typeof(this)))
            this(ref scope typeof(this) rhs)const shared @safe{this(rhs, Forward.init);}
        else
            @disable this(ref scope typeof(this) rhs)const shared @safe;



        /**
            Assign.

            Examples:
                --------------------
                {
                    GlobalPtr!long x = new long(1);

                    x = null;
                    assert(x == null);
                }

                {
                    GlobalPtr!(shared long) x = new shared(long)(1);

                    x = null;
                    assert(x == null);
                }

                {
                    shared GlobalPtr!(long) x = new shared(long)(1);

                    x = null;
                    assert(x == null);
                }
                --------------------
        */
        public void opAssign(typeof(null) nil)scope pure nothrow @trusted @nogc{
            this._set_element(null);
        }

        /// ditto
        public void opAssign(typeof(null) nil)shared scope pure nothrow @trusted @nogc{
            this._set_element(null);
        }

        /// ditto
        public void opAssign(ElementReferenceType elm)scope pure nothrow @trusted @nogc{
            this._set_element(elm);
        }



        /**
            Shares ownership of the object managed by `rhs`.

            If `rhs` manages no object, `this` manages no object too.
            If `rhs` is rvalue then move-assigns a `RcPtr` from `rhs`

            Examples:
                --------------------
                {
                    GlobalPtr!long px1 = new long(1);
                    GlobalPtr!long px2 = new long(2);

                    px1 = px2;
                    assert(*px1 == 2);
                }


                {
                    GlobalPtr!long px = new long(1);
                    GlobalPtr!(const long) pcx = new long(2);

                    pcx = px;
                    assert(*pcx == 1);
                }


                {
                    const GlobalPtr!long cpx = new long(1);
                    GlobalPtr!(const long) pcx = new long(2);

                    pcx = cpx;
                    assert(*pcx == 1);
                }

                {
                    GlobalPtr!(immutable long) pix = new immutable(long)(123);
                    GlobalPtr!(const long) pcx = new long(2);

                    pcx = pix;
                    assert(*pcx == 123);
                }
                --------------------
        */
        public void opAssign(Rhs, this This)(scope auto ref Rhs desired)scope @trusted
        if(isGlobalPtr!Rhs
            && isAssignable!(Rhs, This)
            && !is(Rhs == shared)
        ){
            this._set_element(desired._element);
        }



        /**
            Swap `this` with `rhs`

            Examples:
                --------------------
                {
                    GlobalPtr!long a = new long(1);
                    GlobalPtr!long b = new long(2);

                    a.proxySwap(b);
                    assert(*a == 2);
                    assert(*b == 1);

                    import std.algorithm : swap;
                    swap(a, b);
                    assert(*a == 1);
                    assert(*b == 2);
                }
                --------------------
        */
        public void proxySwap(ref scope typeof(this) rhs)scope @trusted pure nothrow @nogc{
            auto element = this._element;
            this._set_element(rhs._element);
            rhs._set_element(element);
        }



        /**

        */
        alias get this;



        /**
            Operator *, same as method 'get'.

            Examples:
                --------------------
                GlobalPtr!long x = new long(123);
                assert(*x == 123);

                (*x = 321);
                assert(*x == 321);

                const y = x;
                assert(*y == 321);
                assert(*x == 321);

                static assert(is(typeof(*y) == const long));
                --------------------
        */
        public template opUnary(string op : "*")
        if(op == "*"){  //doc
            alias opUnary = get;
        }



        /**
            Get reference to managed object of `ElementType` or value if `ElementType` is reference type (class or interface) or dynamic array.

            Examples:
                --------------------
                GlobalPtr!long x = new long(123);
                assert(x.get == 123);

                x.get = 321;
                assert(x.get == 321);

                const y = x;
                assert(y.get == 321);
                assert(x.get == 321);

                static assert(is(typeof(y.get) == const long));
                --------------------
        */
        static if(referenceElementType){
            public @property inout(ElementType) get()inout scope pure nothrow @trusted @nogc{
                return this._element;
            }
        }
        else static if(is(Unqual!ElementType == void)){
            /// ditto
            public @property inout(void) get()inout scope pure nothrow @safe @nogc{
            }
        }
        else{
            /// ditto
            public @property ref inout(ElementType) get()inout scope pure nothrow @trusted @nogc{
                return *cast(inout(ElementType)*)this._element;
            }
        }



        /**
            Get pointer to managed object of `ElementType` or reference if `ElementType` is reference type (class or interface) or dynamic array.

            Examples:
                --------------------
                {
                    GlobalPtr!long x = new long(123);
                    assert(*x.element == 123);

                    x.get = 321;
                    assert(*x.element == 321);

                    const y = x;
                    assert(*y.element == 321);
                    assert(*x.element == 321);

                    static assert(is(typeof(y.element) == const(long)*));
                }
                --------------------
        */
        public @property ElementReferenceTypeImpl!(GetElementType!This) element(this This)()return pure nothrow @trusted @nogc
        if(!is(This == shared)){
            return this._element;
        }



        /**
            Get pointer to managed object of `ElementType` or reference if `ElementType` is reference type (class or interface) or pointer to first dynamic array element.

            Examples:
                --------------------
                {
                    GlobalPtr!long x = new long(123);
                    assert(*x.ptr == 123);

                    x.get = 321;
                    assert(*x.ptr == 321);

                    const y = x;
                    assert(*y.ptr == 321);
                    assert(*x.ptr == 321);

                    static assert(is(typeof(y.ptr) == const(long)*));
                }
                --------------------
        */
        public @property ElementPointerTypeImpl!(GetElementType!This) ptr(this This)()return pure nothrow @trusted @nogc
        if(!is(This == shared)){
            static if(isDynamicArray!ElementType)
                return this._element.ptr;
            else
                return this._element;
        }



        /**
            Checks if `this` stores a non-null pointer, i.e. whether `this != null`.

            Examples:
                --------------------
                GlobalPtr!long x = new long(123);
                assert(cast(bool)x);    //explicit cast
                assert(x);              //implicit cast
                
                x = null;
                assert(!cast(bool)x);   //explicit cast
                assert(!x);             //implicit cast
                --------------------
        */
        public bool opCast(To : bool)()const scope pure nothrow @safe @nogc
        if(is(To : bool)){ //docs
            return (this != null);
        }



        /**
            Support for quelifier cast.
        */
        public ref To opCast(To, this This)()return scope pure nothrow @nogc
        if(is(immutable To : immutable typeof(this))){
            static if(is(This : To)){
                return *(()@trusted => cast(To*)&this )();
            }
            else{
                return *(()@system => cast(To*)&this )();
            }
        }


        /**
            Operator == and != .
            Compare pointers.

            Examples:
                --------------------
                {
                    GlobalPtr!long x = new long(0);
                    assert(x != null);
                    x = null;
                    assert(x == null);
                }

                {
                    GlobalPtr!long x = new long(123);
                    GlobalPtr!long y = new long(123);
                    assert(x == x);
                    assert(y == y);
                    assert(x != y);
                }

                {
                    GlobalPtr!long x;
                    GlobalPtr!(const long) y;
                    assert(x == x);
                    assert(y == y);
                    assert(x == y);
                }

                {
                    GlobalPtr!long x = new long(123);
                    GlobalPtr!long y = new long(123);
                    assert(x == x.element);
                    assert(y.element == y);
                    assert(x != y.element);
                }
                --------------------
        */
        public bool opEquals(typeof(null) nil)const @safe scope pure nothrow @nogc{
            static if(isDynamicArray!ElementType)
                return (this._element.length == 0);
            else
                return (this._element is null);
        }

        /// ditto
        public bool opEquals(Rhs)(scope auto ref const Rhs rhs)const @safe scope pure nothrow @nogc
        if(isGlobalPtr!Rhs && !is(Rhs == shared)){
            return this.opEquals(rhs._element);
        }

        /// ditto
        public bool opEquals(Elm)(scope const Elm elm)const @safe scope pure nothrow @nogc
        if(is(Elm : GetElementReferenceType!(typeof(this)))){
            static if(isDynamicArray!ElementType){
                static assert(isDynamicArray!Elm);

                if(this._element.length != elm.length)
                    return false;

                if(this._element.ptr is elm.ptr)
                    return true;

                return (this._element.length == 0);
            }
            else{
                return (this._element is elm);
            }
        }



        /**
            Operators <, <=, >, >= for `RcPtr`.

            Compare address of payload.

            Examples:
                --------------------
                {
                    const GlobalPtr!long a = new long(42);
                    const GlobalPtr!long b = new long(123);
                    const GlobalPtr!long n = GlobalPtr!long.init;

                    assert(a <= a);
                    assert(a >= a);

                    assert((a < b) == !(a >= b));
                    assert((a > b) == !(a <= b));

                    assert(a > n);
                    assert(a > null);

                    assert(n < a);
                    assert(null < a);
                }

                {
                    const GlobalPtr!long a = new long(42);
                    const GlobalPtr!long b = new long(123);

                    assert(a <= a.element);
                    assert(a.element >= a);

                    assert((a < b.element) == !(a.element >= b));
                    assert((a > b.element) == !(a.element <= b));
                }
                --------------------
        */
        public sizediff_t opCmp(typeof(null) nil)const @trusted scope pure nothrow @nogc{
            static if(isDynamicArray!ElementType){
                return this._element.length;
            }
            else{
                return (cast(const void*)this._element) - (cast(const void*)null);
            }

        }

        /// ditto
        public sizediff_t opCmp(Elm)(scope const Elm elm)const @trusted scope pure nothrow @nogc
        if(is(Elm : GetElementReferenceType!(typeof(this)))){
            static if(isDynamicArray!ElementType){
                const void* lhs = cast(const void*)(this._element.ptr + this._element.length);
                const void* rhs = cast(const void*)(elm.ptr + elm.length);

                return lhs - rhs;
            }
            else{
                return (cast(const void*)this._element) - (cast(const void*)elm);
            }
        }

        /// ditto
        public sizediff_t opCmp(Rhs)(scope auto ref const Rhs rhs)const @trusted scope pure nothrow @nogc
        if(isGlobalPtr!Rhs && !is(Rhs == shared)){
            return this.opCmp(rhs._element);
        }



        private ElementReferenceType _element;

        private void _set_element(ElementReferenceType e)pure nothrow @system @nogc{
            (*cast(Unqual!ElementReferenceType*)&this._element) = cast(Unqual!ElementReferenceType)e;
        }

        private void _set_element(ElementReferenceType e)shared pure nothrow @system @nogc{
            import core.atomic : atomicStore;
            atomicStore(
                (*cast(Unqual!ElementReferenceType*)&this._element),
                cast(Unqual!ElementReferenceType)e
            );
        }
    }
}


//local traits:
private{

    //Constructable:
    alias isCopyConstructable = isConstructable;

    template isConstructable(From, To){
        enum bool isConstructable = true
            && is(GetElementReferenceType!From : GetElementReferenceType!To);
    }

    //Assignable:
    template isAssignable(From, To){
        import std.traits : isMutable;
        enum bool isAssignable = true
            && isMutable!To
            && isConstructable!(From, To);
    }
}


version(unittest){
    //this(null)
    nothrow @nogc @safe unittest{
        GlobalPtr!long x = null;

        assert(x == null);
        assert(x == GlobalPtr!long.init);
    }

    //this(elm)
    nothrow @safe unittest{
        {
            GlobalPtr!long x = new long(42);

            assert(x != null);
            assert(x.get == 42);
        }

        {
            static const long i = 42;
            GlobalPtr!(const long) x = &i;

            assert(x != null);
            assert(x.get == 42);
        }
    }

    //opAssign(null|elm)
    nothrow @safe unittest{
        {
            GlobalPtr!long x = new long(1);

            x = null;
            assert(x == null);
        }

        {
            GlobalPtr!(shared long) x = new shared(long)(1);

            x = null;
            assert(x == null);
        }

        {
            shared GlobalPtr!(long) x = new shared(long)(1);

            x = null;
            //assert(x == null);
        }

    }

    //opAssign(this)
    nothrow @safe unittest{
        {
            GlobalPtr!long px1 = new long(1);
            GlobalPtr!long px2 = new long(2);

            px1 = px2;
            assert(*px1 == 2);
        }


        {
            GlobalPtr!long px = new long(1);
            GlobalPtr!(const long) pcx = new long(2);

            pcx = px;
            assert(*pcx == 1);
        }


        {
            const GlobalPtr!long cpx = new long(1);
            GlobalPtr!(const long) pcx = new long(2);

            pcx = cpx;
            assert(*pcx == 1);
        }

        {
            GlobalPtr!(immutable long) pix = new immutable(long)(123);
            GlobalPtr!(const long) pcx = new long(2);

            pcx = pix;
            assert(*pcx == 123);
        }
    }

    //proxySwap
    nothrow @safe unittest{
        {
            GlobalPtr!long a = new long(1);
            GlobalPtr!long b = new long(2);

            a.proxySwap(b);
            assert(*a == 2);
            assert(*b == 1);

            import std.algorithm : swap;
            swap(a, b);
            assert(*a == 1);
            assert(*b == 2);
        }
    }

    //opUnary!*
    nothrow @safe unittest{
        GlobalPtr!long x = new long(123);
        assert(*x == 123);

        (*x = 321);
        assert(*x == 321);

        const y = x;
        assert(*y == 321);
        assert(*x == 321);

        static assert(is(typeof(*y) == const long));
    }

    //get
    nothrow @safe unittest{
        GlobalPtr!long x = new long(123);
        assert(x.get == 123);

        x.get = 321;
        assert(x.get == 321);

        const y = x;
        assert(y.get == 321);
        assert(x.get == 321);

        static assert(is(typeof(y.get) == const long));
    }

    //element
    nothrow @safe unittest{
        {
            GlobalPtr!long x = new long(123);
            assert(*x.element == 123);

            x.get = 321;
            assert(*x.element == 321);

            const y = x;
            assert(*y.element == 321);
            assert(*x.element == 321);

            static assert(is(typeof(y.element) == const(long)*));
        }
    }

    //ptr
    nothrow @safe unittest{
        {
            GlobalPtr!long x = new long(123);
            assert(*x.ptr == 123);

            x.get = 321;
            assert(*x.ptr == 321);

            const y = x;
            assert(*y.ptr == 321);
            assert(*x.ptr == 321);

            static assert(is(typeof(y.ptr) == const(long)*));
        }
    }

    //opCast!bool
    nothrow @safe unittest{
        GlobalPtr!long x = new long(123);
        assert(cast(bool)x);    //explicit cast
        assert(x);              //implicit cast

        x = null;
        assert(!cast(bool)x);   //explicit cast
        assert(!x);             //implicit cast
    }

    //opEquals
    nothrow @safe unittest{
        {
            GlobalPtr!long x = new long(0);
            assert(x != null);
            x = null;
            assert(x == null);
        }

        {
            GlobalPtr!long x = new long(123);
            GlobalPtr!long y = new long(123);
            assert(x == x);
            assert(y == y);
            assert(x != y);
        }

        {
            GlobalPtr!long x;
            GlobalPtr!(const long) y;
            assert(x == x);
            assert(y == y);
            assert(x == y);
        }

        {
            GlobalPtr!long x = new long(123);
            GlobalPtr!long y = new long(123);
            assert(x == x.element);
            assert(y.element == y);
            assert(x != y.element);
        }
    }

    //opCmp
    nothrow @safe unittest{
        {
            const GlobalPtr!long a = new long(42);
            const GlobalPtr!long b = new long(123);
            const GlobalPtr!long n = GlobalPtr!long.init;

            assert(a <= a);
            assert(a >= a);

            assert((a < b) == !(a >= b));
            assert((a > b) == !(a <= b));

            assert(a > n);
            assert(a > null);

            assert(n < a);
            assert(null < a);
        }

        {
            const GlobalPtr!long a = new long(42);
            const GlobalPtr!long b = new long(123);

            assert(a <= a.element);
            assert(a.element >= a);

            assert((a < b.element) == !(a.element >= b));
            assert((a > b.element) == !(a.element <= b));
        }
    }

}
