/**
    Implementation of intrusive reference counted pointer `IntrusivePtr` (similar to c++ `std::enable_shared_from_this`).

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/basic_string, Adam Búš)
*/
module btl.autoptr.intrusive_ptr;

import btl.internal.allocator;
import btl.internal.traits;
import btl.internal.gc;

import btl.autoptr.common;


/**
    Check if type `T` is `IntrusivePtr`.
*/
public template isIntrusivePtr(T){
    import std.traits : isInstanceOf;

    enum bool isIntrusivePtr = isInstanceOf!(IntrusivePtr, T);
}

///
unittest{
    static assert(!isIntrusivePtr!long);
    static assert(!isIntrusivePtr!(void*));

    static struct Foo{
        ControlBlock!(int, int) control;
    }
    static assert(isIntrusivePtr!(IntrusivePtr!Foo));
    static assert(isIntrusivePtr!(IntrusivePtr!Foo.WeakType));
}



/**
    Implementation of a ref counted pointer that points to an object with an embedded reference counter `btl.autoptr.common.ControlBlock`.

    `IntrusivePtr` retains shared ownership of an object through a pointer.

    Several ref counted pointer objects may own the same object.

    The object is destroyed and its memory deallocated when either of the following happens:

        1. the last remaining ref counted pointer owning the object is destroyed.

        2. the last remaining ref counted pointer owning the object is assigned another pointer via various methods like `opAssign` and `store`.

    The object is destroyed using destructor of type `_Type`.

    A `IntrusivePtr` can not share ownership of an object while storing a pointer to another object (use `SharedPtr` for that).

    A `IntrusivePtr` may also own no objects, in which case it is called empty.

    `_Type` must contain one property of type `ControlBlock` (this property contains ref counting). If this property is `shared` then ref counting is atomic.

    If `_Type` is const/immutable then ControlBlock cannot be modified => ref counting doesn't work and `IntrusivePtr` can be only moved.

    If multiple threads of execution access the same `IntrusivePtr` (`shared IntrusivePtr`) then only some methods can be called (`load`, `store`, `exchange`, `compareExchange`, `useCount`).

    Template parameters:

        `_Type` type of managed object

        `_weakPtr` if `true` then `IntrusivePtr` represent weak ptr

*/
public template IntrusivePtr(
    _Type,
    bool _weakPtr = false
){
    static assert(is(_Type == struct) || is(_Type == class),
        "intrusive pointer type must be class or struct"
    );

    static assert(isIntrusive!_Type,
        "type `" ~ _Type.stringof ~ "` must have member of type `ControlBlock`"
    );

    static assert(isIntrusive!_Type == 1,
        "type `" ~ _Type.stringof ~ "` must have only one member of type `ControlBlock`"
    );

    static assert(!_weakPtr || _ControlType.hasWeakCounter,
        "weak pointer must have control block with weak counter"
    );

    static assert(!__traits(isNested, _Type),
        "IntrusivePtr does not support nested types."
    );

    static assert(_ControlType.hasSharedCounter,
        "ControlBlock in IntrusivePtr must have shared counter"
    );

    import std.meta : AliasSeq;
    import std.range : ElementEncodingType;
    import std.traits: Unqual, Unconst, CopyTypeQualifiers, CopyConstness, PointerTarget,
        hasIndirections, hasElaborateDestructor,
        isMutable, isAbstractClass, isDynamicArray, isStaticArray, isCallable, Select, isArray;

    import core.atomic : MemoryOrder;
    import core.lifetime : forward;


    alias _ControlType = IntrusiveControlBlock!_Type;

    enum bool hasWeakCounter = _ControlType.hasWeakCounter;

    enum bool hasSharedCounter = _ControlType.hasSharedCounter;

    enum bool _isLockFree = true;

    struct IntrusivePtr{

        /**
            Type of element managed by `IntrusivePtr`.
        */
        public alias ElementType = _Type;


        /**
            Type of destructor (`void function(void*)@attributes`).
        */
        public alias DestructorType = .DestructorType!ElementType;


        /**
            Type of control block.
        */
        public alias ControlType = _ControlType;


        /**
            `true` if `ControlBlock` is shared
        */
        public enum bool sharedControl = is(IntrusiveControlBlock!(ElementType, true) == shared);


        /**
            `true` if `IntrusivePtr` is weak ptr.
        */
        public alias isWeak = _weakPtr;


        /**
            Same as `ElementType*` or `ElementType` if is class/interface/slice.
        */
        public alias ElementReferenceType = ElementReferenceTypeImpl!ElementType;


        /**
            Weak pointer

            `IntrusivePtr.WeakType` is a smart pointer that holds a non-owning ("weak") reference to an object that is managed by `IntrusivePtr`.
            It must be converted to `IntrusivePtr` in order to access the referenced object.

            `IntrusivePtr.WeakType` models temporary ownership: when an object needs to be accessed only if it exists, and it may be deleted at any time by someone else,
            `IntrusivePtr.WeakType` is used to track the object, and it is converted to `IntrusivePtr` to assume temporary ownership.
            If the original `IntrusivePtr` is destroyed at this time, the object's lifetime is extended until the temporary `IntrusivePtr` is destroyed as well.

            Another use for `IntrusivePtr.WeakType` is to break reference cycles formed by objects managed by `IntrusivePtr`.
            If such cycle is orphaned (i,e. there are no outside shared pointers into the cycle), the `IntrusivePtr` reference counts cannot reach zero and the memory is leaked.
            To prevent this, one of the pointers in the cycle can be made weak.
        */
        static if(hasWeakCounter)
            public alias WeakType = IntrusivePtr!(
                _Type,
                true
            );
        else
            public alias WeakType = void;


        /**
            Type of non weak ptr.
        */
        public alias SharedType = IntrusivePtr!(
            _Type,
            false
        );


        /**
            `true` if shared `IntrusivePtr` has lock free operations `store`, `load`, `exchange`, `compareExchange`, otherwise 'false'
        */
        public alias isLockFree = _isLockFree;

        static if(isLockFree)
            static assert(ElementReferenceType.sizeof == size_t.sizeof);



        /**
            Destructor

            If `this` owns an object and it is the last `IntrusivePtr` owning it, the object is destroyed.
            After the destruction, the smart pointers that shared ownership with `this`, if any, will report a `useCount()` that is one less than its previous value.
        */
        public ~this(){
            this._release();
        }


        //necesary for btl.autoptr.unique_ptr.sharedPtr
        package this(Elm, this This)(Elm element, Forward)pure nothrow @safe @nogc
        if(true
            && is(Elm : GetElementReferenceType!This)
            && !is(Unqual!Elm == typeof(null))
        ){
            this._element = element;
        }


        /**
            Forward constructor (merge move and copy constructor).
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs, Forward)@trusted
        if(    isIntrusivePtr!Rhs
            && isConstructable!(rhs, This)
            && !is(Rhs == shared)
        ){
            //lock (copy):
            static if(weakLock!(Rhs, This)){
                if(rhs._element !is null && rhs._control.add_shared_if_exists())
                    this._element = rhs._element;
                else
                    this._element = null;
            }
            //copy:
            else static if(isRef!rhs){
                static assert(isCopyConstructable!(Rhs, This));

                if(rhs._element is null){
                    this(null);
                }
                else{
                    this(rhs._element, Forward.init);
                    rhs._control.add!isWeak;
                }
            }
            //move:
            else{
                static assert(isMoveConstructable!(Rhs, This));

                this._element = rhs._element;

                static if(isWeak && !Rhs.isWeak){
                    if(this._element !is null)
                        this._control.add!isWeak;
                }
                else{
                    rhs._const_reset();
                }
            }
        }


        /**
            Constructs a `IntrusivePtr` without managed object. Same as `IntrusivePtr.init`

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                }

                {
                    IntrusivePtr!Foo x = null;

                    assert(x == null);
                    assert(x == IntrusivePtr!Foo.init);
                }
                --------------------
        */
        public this(this This)(typeof(null) nil)pure nothrow @safe @nogc{
        }



        /**
            Constructs a `IntrusivePtr` which shares ownership of the object managed by `rhs`.

            If rhs manages no object, this manages no object too.
            If rhs if rvalue then ownership is moved.
            The template overload doesn't participate in overload resolution if ElementType of `typeof(rhs)` is not implicitly convertible to `ElementType`.
            If rhs if `WeakType` then this ctor is equivalent to `this(rhs.lock())`.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                    assert(x.useCount == 1);

                    IntrusivePtr!Foo a = x;         //lvalue copy ctor
                    assert(a == x);

                    const IntrusivePtr!Foo b = x;   //lvalue copy ctor
                    assert(b == x);

                    IntrusivePtr!Foo c = x; //lvalue ctor
                    assert(c == x);

                    //const IntrusivePtr!Foo d = b;   //lvalue ctor
                    //assert(d == x);

                    assert(x.useCount == 4);
                }

                {
                    import core.lifetime : move;
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                    assert(x.useCount == 1);

                    IntrusivePtr!Foo a = move(x);        //rvalue copy ctor
                    assert(a.useCount == 1);

                    const IntrusivePtr!Foo b = move(a);  //rvalue copy ctor
                    assert(b.useCount == 1);

                    IntrusivePtr!(const Foo) c = b.load;  //rvalue ctor
                    assert(c.useCount == 2);

                    const IntrusivePtr!Foo d = move(c);  //rvalue ctor
                    assert(d.useCount == 2);
                }
                --------------------
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs)@trusted
        if(    isIntrusivePtr!Rhs
            && isConstructable!(rhs, This)
            && !is(Rhs == shared)
            && !isMoveCtor!(This, rhs)
        ){
            this(forward!rhs, Forward.init);
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


        /+
        //Not neccesary:
        static foreach(alias From; AliasSeq!(
            const typeof(this),
            immutable typeof(this),
            shared typeof(this),
            const shared typeof(this)
        )){
            @disable this(ref scope From rhs)@safe;
            @disable this(ref scope From rhs)const @safe;
            @disable this(ref scope From rhs)immutable @safe;
            @disable this(ref scope From rhs)shared @safe;
            @disable this(ref scope From rhs)const shared @safe;
            //@disable this(ref scope From rhs)pure nothrow @safe @nogc;
        }
        +/


        /**
            Releases the ownership of the managed object, if any.

            After the call, this manages no object.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x == null);
                }

                {
                    IntrusivePtr!(shared Foo) x = IntrusivePtr!(shared Foo).make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x == null);
                }

                {
                    shared IntrusivePtr!(shared Foo) x = IntrusivePtr!(shared Foo).make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x.load == null);

                }
                --------------------
        */
        public void opAssign(MemoryOrder order = MemoryOrder.seq, this This)(typeof(null) nil)scope
        if(isMutable!This){
            static if(is(This == shared)){
                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    ()@trusted{
                        UnqualSmartPtr!This tmp;
                        tmp._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            null
                        ));
                    }();
                }
                else{
                    return this.lockSmartPtr!(
                        (ref scope self) => self.opAssign!order(null)
                    )();
                }
            }
            else{
                this._release();
                ()@trusted{
                    this._reset();
                }();
            }
        }

        /**
            Shares ownership of the object managed by `rhs`.

            If `rhs` manages no object, `this` manages no object too.
            If `rhs` is rvalue then move-assigns a `IntrusivePtr` from `rhs`

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo px1 = IntrusivePtr!Foo.make(1);
                    IntrusivePtr!Foo px2 = IntrusivePtr!Foo.make(2);

                    assert(px2.useCount == 1);
                    px1 = px2;
                    assert(px1.get.i == 2);
                    assert(px2.useCount == 2);
                }


                {
                    IntrusivePtr!(Foo) px = IntrusivePtr!(Foo).make(1);
                    IntrusivePtr!(const Foo) pcx = IntrusivePtr!(Foo).make(2);

                    assert(px.useCount == 1);
                    pcx = px;
                    assert(pcx.get.i == 1);
                    assert(pcx.useCount == 2);
                }
                --------------------
        */
        public void opAssign(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(scope auto ref Rhs desired)scope
        if(    isIntrusivePtr!Rhs
            && isAssignable!(desired, This)
            && !is(Rhs == shared)
        ){
            // shared assign:
            static if(is(This == shared)){
                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    static if(isRef!desired && (This.isWeak == Rhs.isWeak)){
                        if((()@trusted => cast(const void*)&desired is cast(const void*)&this)())
                            return;
                    }

                    ()@trusted{
                        UnqualSmartPtr!This tmp_desired = forward!desired;
                        //desired._control.add!(This.isWeak);

                        UnqualSmartPtr!This tmp;
                        GetElementReferenceType!This source = tmp_desired._element;    //interface/class cast

                        tmp._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            cast(Unqual!(This.ElementReferenceType))source
                        ));

                        tmp_desired._const_reset();
                    }();
                }
                else{
                    this.lockSmartPtr!(
                        (ref scope self, scope auto ref Rhs x) => self.opAssign!order(forward!x)
                    )(forward!desired);
                }
            }
            // copy assign or non identity move assign:
            else static if(isRef!desired || !is(This == Rhs)){

                static if(isRef!desired && (This.isWeak == Rhs.isWeak)){
                    if((()@trusted => cast(const void*)&desired is cast(const void*)&this)())
                        return;
                }

                this._release();

                auto tmp = This(forward!desired);

                ()@trusted{
                    this._set_element(tmp._element);
                    tmp._const_reset();
                }();
            }
            //identity move assign:   //separate case for core.lifetime.move
            else{
                static assert(isMoveAssignable!(Rhs, This));
                static assert(!isRef!desired);

                this._release();

                ()@trusted{
                    this._set_element(desired._element);
                    desired._const_reset();
                }();

            }
        }



        /**
            Constructs an object of type `ElementType` and wraps it in a `IntrusivePtr` using args as the parameter list for the constructor of `ElementType`.

            The object is constructed as if by the expression `emplace!ElementType(_payload, forward!args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof` in order to use one allocation for both the control block and the `ElementType` object.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo a = IntrusivePtr!Foo.make();
                    assert(a.get.i == 0);

                    IntrusivePtr!(const Foo) b = IntrusivePtr!Foo.make(2);
                    assert(b.get.i == 2);
                }

                {
                    static struct Struct{
                        ControlBlock!int c;
                        int i = 7;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    IntrusivePtr!Struct s1 = IntrusivePtr!Struct.make();
                    assert(s1.get.i == 7);

                    IntrusivePtr!Struct s2 = IntrusivePtr!Struct.make(123);
                    assert(s2.get.i == 123);
                }
                --------------------
        */
        public static IntrusivePtr!ElementType make(AllocatorType = DefaultAllocator, bool supportGC = platformSupportGC, Args...)(auto ref Args args){

            static assert(is(DestructorAllocatorType!AllocatorType : DestructorType));

            auto m = typeof(return).MakeIntrusive!(AllocatorType, supportGC).make(AllocatorType.init, forward!(args));

            return (m is null)
                ? typeof(return).init
                : typeof(return)(m.get, Forward.init);
        }



        /**
            Constructs an object of type `ElementType` and wraps it in a `IntrusivePtr` using args as the parameter list for the constructor of `ElementType`.

            The object is constructed as if by the expression `emplace!ElementType(_payload, forward!args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof` in order to use one allocation for both the control block and the `ElementType` object.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    import std.experimental.allocator : allocatorObject;

                    auto a = allocatorObject(Mallocator.instance);
                    {
                        auto x = IntrusivePtr!Foo.alloc(a);
                        assert(x.get.i == 0);

                        auto y = IntrusivePtr!(const Foo).alloc(a, 2);
                        assert(y.get.i == 2);
                    }

                    {
                        static struct Struct{
                            ControlBlock!(int) c;
                            int i = 7;

                            this(int i)pure nothrow @safe @nogc{
                                this.i = i;
                            }
                        }

                        auto s1 = IntrusivePtr!Struct.alloc(a);
                        assert(s1.get.i == 7);

                        auto s2 = IntrusivePtr!Struct.alloc(a, 123);
                        assert(s2.get.i == 123);
                    }

                }
                --------------------
        */
        public static IntrusivePtr!ElementType alloc(bool supportGC = platformSupportGC, AllocatorType, Args...)(AllocatorType a, auto ref Args args){

            static assert(is(DestructorAllocatorType!AllocatorType : DestructorType),
                DestructorAllocatorType!AllocatorType.stringof ~ " : " ~ DestructorType.stringof
            );

            auto m = typeof(return).MakeIntrusive!(AllocatorType, supportGC).make(forward!(a, args));

            return (m is null)
                ? typeof(return).init
                : typeof(return)(m.get, Forward.init);
        }



        /**
            Returns the number of different `IntrusivePtr` instances

            Returns the number of different `IntrusivePtr` instances (`this` included) managing the current object or `0` if there is no managed object.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }


                IntrusivePtr!Foo x = null;

                assert(x.useCount == 0);

                x = IntrusivePtr!Foo.make(123);
                assert(x.useCount == 1);

                auto y = x;
                assert(x.useCount == 2);

                auto w1 = x.weak;    //weak ptr
                assert(x.useCount == 2);

                IntrusivePtr!Foo.WeakType w2 = x;   //weak ptr
                assert(x.useCount == 2);

                y = null;
                assert(x.useCount == 1);

                x = null;
                assert(x.useCount == 0);
                assert(w1.useCount == 0);
                --------------------
        */
        public @property ControlType.Shared useCount(this This)()const scope nothrow @safe @nogc{

            static if(is(This == shared))
                return this.lockSmartPtr!(
                    (ref scope self) => self.useCount()
                )();

            else
                return (this._element is null)
                    ? 0
                    : this._control.count!false + 1;
        }


        /**
            Returns the number of different `IntrusivePtr.WeakType` instances

            Returns the number of different `IntrusivePtr.WeakType` instances (`this` included) managing the current object or `0` if there is no managed object.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                IntrusivePtr!Foo x = null;
                assert(x.useCount == 0);
                assert(x.weakCount == 0);

                x = IntrusivePtr!Foo.make(123);
                assert(x.useCount == 1);
                assert(x.weakCount == 0);

                auto w = x.weak();
                assert(x.useCount == 1);
                assert(x.weakCount == 1);
                --------------------
        */
        public @property ControlType.Weak weakCount(this This)()const scope nothrow @safe @nogc{

            static if(is(This == shared))
                return this.lockSharedPtr!(
                    (ref scope self) => self.weakCount()
                )();

            else
                return (this._element is null)
                    ? 0
                    : this._control.count!true;
        }



        /**
            Swap `this` with `rhs`

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo a = IntrusivePtr!Foo.make(1);
                    IntrusivePtr!Foo b = IntrusivePtr!Foo.make(2);
                    a.proxySwap(b);
                    assert(a != null);
                    assert(b != null);
                    assert(a.get.i == 2);
                    assert(b.get.i == 1);
                    import std.algorithm : swap;
                    swap(a, b);
                    assert(a.get.i == 1);
                    assert(b.get.i == 2);
                    assert(a.useCount == 1);
                    assert(b.useCount == 1);
                }
                --------------------
        */
        public void proxySwap(ref scope typeof(this) rhs)scope @trusted pure nothrow @nogc{
            auto element = this._element;
            this._set_element(rhs._element);
            rhs._set_element(element);
        }



        /**
            Returns the non `shared` `IntrusivePtr` pointer pointed-to by `shared` `this`.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                shared IntrusivePtr!(shared Foo) x = IntrusivePtr!(shared Foo).make(123);

                {
                    IntrusivePtr!(shared Foo) y = x.load();
                    assert(y.useCount == 2);

                    assert(y.get.i == 123);
                }
                --------------------
        */
        public UnqualSmartPtr!This
        load(MemoryOrder order = MemoryOrder.seq, this This)()scope{  //TODO remove return
            static assert(isCopyConstructable!(Unshared!This, typeof(return)));

            static if(is(This == shared))
                return this.lockSmartPtr!(
                    (ref scope self) => self.load!order()
                )();

            else
                return typeof(return)(this);
        }



        /**
            Stores the non `shared` `IntrusivePtr` parameter `ptr` to `this`.

            If `this` is shared then operation is atomic or guarded by mutex.

            Template parameter `order` has type `core.atomic.MemoryOrder`.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                //null store:
                {
                    shared x = IntrusivePtr!(shared Foo).make(123);
                    assert(x.load.get.i == 123);

                    x.store(null);
                    assert(x.useCount == 0);
                    assert(x.load == null);
                }

                //rvalue store:
                {
                    shared x = IntrusivePtr!(shared Foo).make(123);
                    assert(x.load.get.i == 123);

                    x.store(IntrusivePtr!(shared Foo).make(42));
                    assert(x.load.get.i == 42);
                }

                //lvalue store:
                {
                    shared x = IntrusivePtr!(shared Foo).make(123);
                    auto y = IntrusivePtr!(shared Foo).make(42);

                    assert(x.load.get.i == 123);
                    assert(y.load.get.i == 42);

                    x.store(y);
                    assert(x.load.get.i == 42);
                    assert(x.useCount == 2);
                }
                --------------------
        */
        public alias store = opAssign;



        /**
            Stores the non `shared` `IntrusivePtr` pointer ptr in the `shared(IntrusivePtr)` pointed to by `this` and returns the value formerly pointed-to by this, atomically or with mutex.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                //lvalue exchange
                {
                    shared x = IntrusivePtr!(shared Foo).make(123);
                    auto y = IntrusivePtr!(shared Foo).make(42);

                    auto z = x.exchange(y);

                    assert(x.load.get.i == 42);
                    assert(y.get.i == 42);
                    assert(z.get.i == 123);
                }

                //rvalue exchange
                {
                    shared x = IntrusivePtr!(shared Foo).make(123);
                    auto y = IntrusivePtr!(shared Foo).make(42);

                    import core.lifetime : move;
                    auto z = x.exchange(move(y));

                    assert(x.load.get.i == 42);
                    assert(y == null);
                    assert(z.get.i == 123);
                }

                //null exchange (same as move)
                {
                    shared x = IntrusivePtr!(shared Foo).make(123);

                    auto z = x.exchange(null);

                    assert(x.load == null);
                    assert(z.get.i == 123);
                }

                //swap:
                {
                    shared x = IntrusivePtr!(shared Foo).make(123);
                    auto y = IntrusivePtr!(shared Foo).make(42);

                    //opAssign is same as store
                    import core.lifetime : move;
                    y = x.exchange(move(y));

                    assert(x.load.get.i == 42);
                    assert(y.get.i == 123);
                }
                --------------------
        */
        public IntrusivePtr exchange(MemoryOrder order = MemoryOrder.seq, this This)(typeof(null))scope
        if(isMutable!This){

            static if(is(This == shared)){
                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    return()@trusted{
                        UnqualSmartPtr!This result;
                        result._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            null
                        ));

                        return result._move;
                    }();
                }
                else{
                    return this.lockSmartPtr!(
                        (ref scope self) => self.exchange!order(null)
                    )();
                }
            }
            else{
                return this._move;
            }
        }

        /// ditto
        public IntrusivePtr exchange(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(scope Rhs ptr)scope
        if(    isIntrusivePtr!Rhs
            && !is(Rhs == shared)
            && isMoveConstructable!(Rhs, This)
            && isMutable!This
        ){
            static if(is(This == shared)){

                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    return()@trusted{
                        UnqualSmartPtr!This result;
                        GetElementReferenceType!This source = ptr._element;    //interface/class cast

                        result._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            cast(Unqual!(This.ElementReferenceType))source
                        ));
                        ptr._const_reset();

                        return result._move;
                    }();
                }
                else{
                    return this.lockSmartPtr!(
                        (ref scope self, Rhs x) => self.exchange!order(x._move)
                    )(ptr._move);
                }
            }
            else{
                auto result = this._move;

                return()@trusted{
                    this = ptr._move;
                    return result._move;
                }();
            }
        }


        /**
            Compares the `IntrusivePtr` pointers pointed-to by `this` and `expected`.

            If they are equivalent (store the same pointer value, and either share ownership of the same object or are both empty), assigns `desired` into `this` using the memory ordering constraints specified by `success` and returns `true`.
            If they are not equivalent, assigns `this` into `expected` using the memory ordering constraints specified by `failure` and returns `false`.

            More info in c++ std::atomic<std::shared_ptr>.


            Examples:
                --------------------
                static class Foo{
                    long i;
                    ControlBlock!(int, int) c;

                    this(long i)pure nothrow @safe @nogc{
                        this.i = i;
                    }

                    bool opEquals(this This)(long i)const @trusted{
                        import std.traits : Unqual;
                        auto self = cast(Unqual!This)this;
                        return (self.i == i);
                    }


                }
                alias Type = Foo;
                static foreach(enum bool weak; [true, false]){
                    //fail
                    {
                        IntrusivePtr!Type a = IntrusivePtr!Type.make(123);
                        IntrusivePtr!Type b = IntrusivePtr!Type.make(42);
                        IntrusivePtr!Type c = IntrusivePtr!Type.make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        assert(*a == 123);
                        assert(*b == 123);
                        assert(*c == 666);

                    }

                    //success
                    {
                        IntrusivePtr!Type a = IntrusivePtr!Type.make(123);
                        IntrusivePtr!Type b = a;
                        IntrusivePtr!Type c = IntrusivePtr!Type.make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        assert(*a == 666);
                        assert(*b == 123);
                        assert(*c == 666);
                    }

                    //shared fail
                    {
                        shared IntrusivePtr!(shared Type) a = IntrusivePtr!(shared Type).make(123);
                        IntrusivePtr!(shared Type) b = IntrusivePtr!(shared Type).make(42);
                        IntrusivePtr!(shared Type) c = IntrusivePtr!(shared Type).make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        auto tmp = a.exchange(null);
                        assert(*tmp == 123);
                        assert(*b == 123);
                        assert(*c == 666);
                    }

                    //shared success
                    {
                        IntrusivePtr!(shared Type) b = IntrusivePtr!(shared Type).make(123);
                        shared IntrusivePtr!(shared Type) a = b;
                        IntrusivePtr!(shared Type) c = IntrusivePtr!(shared Type).make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        auto tmp = a.exchange(null);
                        assert(*tmp == 666);
                        assert(*b == 123);
                        assert(*c == 666);
                    }
                }
                --------------------
        */
        public bool compareExchangeStrong
            (MemoryOrder success = MemoryOrder.seq, MemoryOrder failure = success, E, D, this This)
            (ref scope E expected, scope D desired)scope
        if(    isIntrusivePtr!E && !is(E == shared)
            && isIntrusivePtr!D && !is(D == shared)
            && (isMoveConstructable!(D, This) && isMutable!This)
            && (isCopyConstructable!(This, E) && isMutable!E)
            && (This.isWeak == D.isWeak)
            && (This.isWeak == E.isWeak)
        ){
            return this.compareExchangeImpl!(false, success, failure)(expected, desired._move);
        }



        /**
            Same as `compareExchangeStrong` but may fail spuriously.

            More info in c++ `std::atomic<std::shared_ptr>`.
        */
        public bool compareExchangeWeak
            (MemoryOrder success = MemoryOrder.seq, MemoryOrder failure = success, E, D, this This)
            (ref scope E expected, scope D desired)scope
        if(    isIntrusivePtr!E && !is(E == shared)
            && isIntrusivePtr!D && !is(D == shared)
            && (isMoveConstructable!(D, This) && isMutable!This)
            && (isCopyConstructable!(This, E) && isMutable!E)
            && (This.isWeak == D.isWeak)
            && (This.isWeak == E.isWeak)
        ){
            return this.compareExchangeImpl!(true, success, failure)(expected, desired._move);
        }


        /*
            implementation of `compareExchangeWeak` and `compareExchangeStrong`
        */
        private bool compareExchangeImpl
            (bool weak, MemoryOrder success, MemoryOrder failure, E, D, this This)
            (ref scope E expected, scope D desired)scope //@trusted pure @nogc
        if(    isIntrusivePtr!E && !is(E == shared)
            && isIntrusivePtr!D && !is(D == shared)
            && (isMoveConstructable!(D, This) && isMutable!This)
            && (isCopyConstructable!(This, E) && isMutable!E)
            && (This.isWeak == D.isWeak)
            && (This.isWeak == E.isWeak)
        ){
            static if(is(This == shared)){
                static if(isLockFree){
                    import core.atomic : cas, casWeak;

                    static if(weak)
                        alias casImpl = casWeak;
                    else
                        alias casImpl = cas;


                    return ()@trusted{
                        GetElementReferenceType!This source_desired = desired._element;     //interface/class cast
                        GetElementReferenceType!This source_expected = expected._element;   //interface/class cast

                        const bool store_occurred = casImpl!(success, failure)(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            cast(Unqual!(This.ElementReferenceType)*)&source_expected,
                            cast(Unqual!(This.ElementReferenceType))source_desired
                        );

                        if(store_occurred){
                            desired._const_reset();
                            if(expected._element !is null)
                                expected._control.release!(This.isWeak);
                        }
                        else{
                            expected = null;
                            expected._set_element(source_expected);
                        }

                        return store_occurred;
                    }();
                }
                else{
                    static assert(!isLockFree);
                    shared mutex = getMutex(this);

                    mutex.lock();

                    alias Self = UnqualSmartPtr!This;

                    static assert(!is(Self == shared));

                    Self* self = cast(Self*)&this;

                    if(*self == expected){
                        auto tmp = self._move;   //destructor is called after  mutex.unlock();
                        *self = desired._move;

                        mutex.unlock();
                        return true;
                    }

                    auto tmp = expected._move;   //destructor is called after  mutex.unlock();
                    expected = *self;

                    mutex.unlock();
                    return false;
                }
            }

            else{
                if(this == expected){
                    this = desired._move;
                    return true;
                }
                expected = this;

                return false;
            }
        }



        /**
            Creates a new non weak `IntrusivePtr` that shares ownership of the managed object (must be `IntrusivePtr.WeakType`).

            If there is no managed object, i.e. this is empty or this is `expired`, then the returned `IntrusivePtr` is empty.
            Method exists only if `IntrusivePtr` is `isWeak`

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);

                    auto w = x.weak;    //weak ptr

                    IntrusivePtr!Foo y = w.lock;

                    assert(x == y);
                    assert(x.useCount == 2);
                    assert(y.get.i == 123);
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);

                    auto w = x.weak;    //weak ptr

                    assert(w.expired == false);

                    x = IntrusivePtr!Foo.make(321);

                    assert(w.expired == true);

                    IntrusivePtr!Foo y = w.lock;

                    assert(y == null);
                }

                {
                    shared IntrusivePtr!(shared Foo) x = IntrusivePtr!(shared Foo).make(123);

                    shared IntrusivePtr!(shared Foo).WeakType w = x.load.weak;    //weak ptr

                    assert(w.expired == false);

                    x = IntrusivePtr!(shared Foo).make(321);

                    assert(w.expired == true);

                    IntrusivePtr!(shared Foo) y = w.load.lock;

                    assert(y == null);
                }
                --------------------
        */
        public SharedType lock()()scope
        if(isCopyConstructable!(typeof(this), SharedType)){
            return typeof(return)(this);
        }



        /**
            Equivalent to `useCount() == 0` (must be `IntrusivePtr.WeakType`).

            Method exists only if `IntrusivePtr` is `isWeak`

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);

                    auto wx = x.weak;   //weak pointer

                    assert(wx.expired == false);

                    x = null;

                    assert(wx.expired == true);
                }
                --------------------
        */
        public @property bool expired(this This)()scope const nothrow @safe @nogc{
            return (this.useCount == 0);
        }



        static if(!isWeak){
            /**
                Operator *, same as method 'get'.

                Examples:
                    --------------------
                    static struct Foo{
                        ControlBlock!(int, int) c;
                        int i;
                        alias i this;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                    assert(*x == 123);
                    ((*x).i = 321);
                    assert(*x == 321);
                    const y = x;
                    assert(*y == 321);
                    assert(*x == 321);
                    static assert(is(typeof(*y) == const Foo));
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
                    static struct Foo{
                        ControlBlock!(int, int) c;
                        int i;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                    assert(x.get.i == 123);
                    x.get.i = 321;
                    assert(x.get.i == 321);
                    const y = x;
                    assert(y.get.i == 321);
                    assert(x.get.i == 321);
                    static assert(is(typeof(y.get) == const Foo));
                    --------------------
            */
            static if(is(ElementType == class)){
                public @property inout(ElementType) get()inout return pure nothrow @safe @nogc{
                    return this._element;
                }
            }
            else static if(is(ElementType == struct)){
                /// ditto
                public @property ref inout(ElementType) get()inout return pure nothrow @system @nogc{
                    return *cast(inout(ElementType)*)this._element;
                }
            }
            else static assert(0, "no impl");

        }



        /**
            Get pointer to managed object of `ElementType` or reference if `ElementType` is reference type (class or interface) or dynamic array

            If `this` is weak expired pointer then return null.

            Doesn't increment useCount, is inherently unsafe.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                    assert(x.element.i == 123);

                    x.get.i = 321;
                    assert(x.element.i == 321);

                    const y = x;
                    assert(y.element.i == 321);
                    assert(x.element.i == 321);

                    static assert(is(typeof(y.element) == const(Foo)*));
                }

                {
                    auto s = IntrusivePtr!Foo.make(42);
                    const w = s.weak;

                    assert(w.element.i == 42);

                    s = null;
                    assert(w.element is null);
                }

                {
                    auto s = IntrusivePtr!Foo.make(42);
                    auto w = s.weak;

                    scope const p = w.element;

                    s = null;
                    assert(w.element is null);

                    assert(p !is null); //p is dangling pointer!
                }
                --------------------
        */
        public @property ElementReferenceTypeImpl!(GetElementType!This) element(this This)()return pure nothrow @system @nogc
        if(!is(This == shared)){
            static if(isWeak)
                return (cast(const)this).expired
                    ? null
                    : this._element;
            else
                return this._element;
        }



        /**
            `.ptr` is same as `.element`
        */
        public alias ptr = element;



        /**
            Returns weak pointer (must have weak counter).

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                assert(x.useCount == 1);

                auto wx = x.weak;   //weak pointer
                assert(wx.expired == false);
                assert(wx.lock.get.i == 123);
                assert(wx.useCount == 1);

                x = null;
                assert(wx.expired == true);
                assert(wx.useCount == 0);
                --------------------
        */
        public WeakType weak()()scope
        if(isCopyConstructable!(typeof(this), WeakType)){
            static if(hasWeakCounter){
                return typeof(return)(this);
            }
        }



        /**
            Checks if `this` stores a non-null pointer, i.e. whether `this != null`.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
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
            Cast `this` to different type `To` when `isIntrusivePtr!To`.

            BUG: qualfied variable of struct with dtor cannot be inside other struct (generated dtor will use opCast to mutable before dtor call ). opCast is renamed to opCastImpl

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;
                    alias i this;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                import std.conv;

                IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                assert(x.useCount == 1
                );
                auto y = cast(IntrusivePtr!(const Foo))x;
                //debug assert(x.useCount == 2, x.useCount.to!string);
                assert(x.useCount == 2);


                auto z = cast(const IntrusivePtr!Foo)x;
                assert(x.useCount == 3);

                auto u = cast(const IntrusivePtr!(const Foo))x;
                assert(x.useCount == 4);
                --------------------
        */
        public To opCastImpl(To, this This)()scope
        if(isIntrusivePtr!To && !is(This == shared)){
            ///copy this -> return
            return To(this);
        }



        /**
            Operator == and != .
            Compare pointers.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(0);
                    assert(x != null);
                    x = null;
                    assert(x == null);
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                    IntrusivePtr!Foo y = IntrusivePtr!Foo.make(123);
                    assert(x == x);
                    assert(y == y);
                    assert(x != y);
                }

                {
                    IntrusivePtr!Foo x;
                    IntrusivePtr!(const Foo) y;
                    assert(x == x);
                    assert(y == y);
                    assert(x == y);
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                    IntrusivePtr!Foo y = IntrusivePtr!Foo.make(123);
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
        if(isIntrusivePtr!Rhs && !is(Rhs == shared)){
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
            Operators <, <=, >, >= for `IntrusivePtr`.

            Compare address of payload.

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    const a = IntrusivePtr!Foo.make(42);
                    const b = IntrusivePtr!Foo.make(123);
                    const n = IntrusivePtr!Foo.init;

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
                    const a = IntrusivePtr!Foo.make(42);
                    const b = IntrusivePtr!Foo.make(123);

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
        if(isIntrusivePtr!Rhs && !is(Rhs == shared)){
            return this.opCmp(rhs._element);
        }



        /**
            Generate hash

            Return:
                Address of payload as `size_t`

            Examples:
                --------------------
                static struct Foo{
                    ControlBlock!(int, int) c;
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                {
                    IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
                    IntrusivePtr!Foo y = IntrusivePtr!Foo.make(123);
                    assert(x.toHash == x.toHash);
                    assert(y.toHash == y.toHash);
                    assert(x.toHash != y.toHash);
                    IntrusivePtr!(const Foo) z = x;
                    assert(x.toHash == z.toHash);
                }
                {
                    IntrusivePtr!Foo x;
                    IntrusivePtr!(const Foo) y;
                    assert(x.toHash == x.toHash);
                    assert(y.toHash == y.toHash);
                    assert(x.toHash == y.toHash);
                }
                --------------------
        */
        public @property size_t toHash()@trusted scope const pure nothrow @nogc {
            static if(isDynamicArray!ElementType)
                return cast(size_t)cast(void*)(this._element.ptr + this._element.length);
            else
                return cast(size_t)cast(void*)this._element;
        }



        package ElementReferenceType _element;


        package auto _control(this This)()scope pure nothrow @trusted @nogc
        in(this._element !is null){
            static if(is(ElementType == class))
                auto control = intrusivControlBlock(this._element);
            else static if(is(ElementType == struct))
                auto control = intrusivControlBlock(*this._element);
            else
                static assert(0, "no impl");


            return *&control;
        }

        private void _set_element(ElementReferenceType e)pure nothrow @system @nogc{
            static if(isMutable!ElementReferenceType)
                this._element = e;
            else
                (*cast(Unqual!ElementReferenceType*)&this._element) = cast(Unqual!ElementReferenceType)e;
        }

        private void _const_set_element(ElementReferenceType e)const pure nothrow @system @nogc{
            auto self = cast(Unqual!(typeof(this))*)&this;

            static if(isMutable!ElementReferenceType)
                self._element = e;
            else
                (*cast(Unqual!ElementReferenceType*)&self._element) = cast(Unqual!ElementReferenceType)e;
        }

        private void _release()scope /*pure nothrow @safe @nogc*/ {
            if(false){
                DestructorType dt;
                dt(null);
            }

            import std.traits : hasIndirections;
            import core.memory : GC;

            if(this._element is null)
                return;

            this._control.release!isWeak;
        }

        private void _reset()scope pure nothrow @system @nogc{
            this._set_element(null);
        }

        package void _const_reset()scope const pure nothrow @system @nogc{
            auto self = cast(Unqual!(typeof(this))*)&this;

            self._reset();
        }

        package auto _move()@trusted{
            auto e = this._element;
            this._const_reset();

            return typeof(this)(e, Forward.init);
        }

        private alias MakeIntrusive(AllocatorType, bool supportGC) = .MakeIntrusive!(
            _Type,
            AllocatorType,
            supportGC
        );



        /**/
        package alias ChangeElementType(T) = IntrusivePtr!(
            CopyTypeQualifiers!(ElementType, T),
            isWeak
        );

        package alias SmartPtr = .SmartPtr;
    }

}

///
nothrow unittest{
    static struct Struct{
        ControlBlock!(int, int) control;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Base{
        int i;
        ControlBlock!(int, int) control;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }
    static class Derived : Base{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }
    static class Class : Derived{
        bool b;
        this(int i, double d, bool b)pure nothrow @safe @nogc{
            super(i, d);
            this.b = b;
        }
    }

    ///simple:
    {
        IntrusivePtr!Struct a = IntrusivePtr!Struct.make(42);
        assert(a.useCount == 1);

        IntrusivePtr!(const Struct) b = a;
        assert(a.useCount == 2);

        IntrusivePtr!Struct.WeakType w = a.weak;
        assert(a.useCount == 2);
        assert(a.weakCount == 1);

        IntrusivePtr!Struct c = w.lock;
        assert(a.useCount == 3);
        assert(a.weakCount == 1);

        assert(c.get.i == 42);
    }

    ///polymorphism and aliasing:
    {
        ///create IntrusivePtr
        IntrusivePtr!Base foo = IntrusivePtr!Derived.make(42, 3.14);
        IntrusivePtr!Class zee = IntrusivePtr!Class.make(42, 3.14, false);

        ///dynamic cast:
        IntrusivePtr!Derived bar = dynCast!Derived(foo);
        assert(bar != null);
        assert(foo.useCount == 2);

        ///this doesnt work because Foo destructor attributes are more restrictive then Class's:
        //IntrusivePtr!Class x = zee;

        ///this does work:
        IntrusivePtr!Base x = zee;
        assert(zee.useCount == 2);
    }


    ///multi threading:
    {
        ///create IntrusivePtr with atomic ref counting
        IntrusivePtr!(shared Base) foo = IntrusivePtr!(shared Derived).make(42, 3.14);

        ///this doesnt work:
        //foo.get.i += 1;

        import core.atomic : atomicFetchAdd;
        atomicFetchAdd(foo.get.i, 1);
        assert(foo.get.i == 43);


        ///creating `shared(IntrusivePtr)`:
        shared IntrusivePtr!(shared Derived) bar = share(dynCast!Derived(foo));

        ///`shared(IntrusivePtr)` is lock free (except `load` and `useCount`/`weakCount`).
        static assert(typeof(bar).isLockFree == true);

        ///multi thread operations (`load`, `store`, `exchange` and `compareExchange`):
        IntrusivePtr!(shared Derived) bar2 = bar.load();
        assert(bar2 != null);
        assert(bar2.useCount == 3);

        IntrusivePtr!(shared Derived) bar3 = bar.exchange(null);
        assert(bar3 != null);
        assert(bar3.useCount == 3);
    }

}

//old:
pure nothrow @nogc unittest{

    static class Foo{
        ControlBlock!(int, int) c;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Bar : Foo{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }

    //implicit qualifier cast
    {
        IntrusivePtr!(const Foo) foo =  IntrusivePtr!Foo.make(42);
        assert(foo.get.i == 42);
        assert(foo.useCount == 1);

        import core.lifetime : move;
        const IntrusivePtr!Foo foo2 = foo.move;
        assert(foo2.get.i == 42);
        assert(foo2.useCount == 1);

    }

    //polymorphic classes:
    {
        IntrusivePtr!Foo foo = IntrusivePtr!Bar.make(42, 3.14);
        assert(foo != null);
        assert(foo.useCount == 1);
        assert(foo.get.i == 42);

        //dynamic cast:
        {
            IntrusivePtr!Bar bar = dynCast!Bar(foo);
            assert(foo.useCount == 2);

            assert(bar.get.i == 42);
            assert(bar.get.d == 3.14);
        }

    }

    //weak references:
    {
        auto x = IntrusivePtr!Foo.make(314);
        assert(x.useCount == 1);
        assert(x.weakCount == 0);

        auto w = x.weak();  //weak pointer
        assert(x.useCount == 1);
        assert(x.weakCount == 1);
        assert(w.lock.get.i == 314);

        IntrusivePtr!Foo.WeakType w2 = x;
        assert(x.useCount == 1);
        assert(x.weakCount == 2);

        assert(w2.expired == false);
        x = null;
        assert(w2.expired == true);
    }
}

///
pure nothrow @safe @nogc unittest{
    //make IntrusivePtr object
    static struct Foo{
        ControlBlock!(int, int) c;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    {
        auto foo = IntrusivePtr!Foo.make(42);
        auto foo2 = IntrusivePtr!Foo.make!Mallocator(42);  //explicit stateless allocator
    }
}

///
nothrow unittest{
    import std.experimental.allocator : make, dispose, allocatorObject;

    static struct Foo{
        ControlBlock!(int, int) c;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }

        ~this(){
            if(false)
                auto allocator = allocatorObject(Mallocator.instance);
        }
    }

    //alloc IntrusivePtr object

    auto allocator = allocatorObject(Mallocator.instance);

    {
        auto x = IntrusivePtr!Foo.alloc(allocator, 42);
    }

}

/**
    Alias to `IntrusivePtr` with additional template parameters for same interface as `SharedPtr` and `RcPtr`
*/
public template IntrusivePtr(
    _Type,
    _DestructorType,
    _ControlType = IntrusiveControlBlock!_Type,
    bool _weakPtr = false
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){

    static assert(is(_ControlType : IntrusiveControlBlock!_Type));

    static assert(is(_DestructorType == .DestructorType!_Type));

    alias IntrusivePtr = .IntrusivePtr!(_Type, _weakPtr);
}

/// ditto
public template IntrusivePtr(
    _Type,
    _ControlType,
    _DestructorType,
    bool _weakPtr = false
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){

    static assert(is(_ControlType : IntrusiveControlBlock!_Type));

    static assert(is(_DestructorType == .DestructorType!_Type));

    alias IntrusivePtr = .IntrusivePtr!(_Type, _weakPtr);
}

//make:
nothrow unittest{
    static class Foo{
        ControlBlock!(int, int) c;
    }

    enum bool supportGC = true;

    {
        auto s = IntrusivePtr!Foo.make();
    }

    {
        auto s = IntrusivePtr!Foo.make!(DefaultAllocator, supportGC)();
    }
}

//alloc:
nothrow unittest{
    import std.experimental.allocator : allocatorObject;

    static class Foo{
        ControlBlock!(int, int) c;

        ~this(){
            if(false)
                auto a = allocatorObject(Mallocator.instance);
        }
    }

    auto a = allocatorObject(Mallocator.instance);
    enum bool supportGC = true;

    {
        auto s = IntrusivePtr!Foo.alloc(a);
    }

    {
        auto s = IntrusivePtr!Foo.alloc!supportGC(a);
    }
}



/**
    Dynamic cast for shared pointers if `ElementType` is class with D linkage.

    Creates a new instance of `IntrusivePtr` whose stored pointer is obtained from `ptr`'s stored pointer using a dynaic cast expression.

    If `ptr` is null or dynamic cast fail then result `IntrusivePtr` is null.
    Otherwise, the new `IntrusivePtr` will share ownership with the initial value of `ptr`.
*/
public UnqualSmartPtr!Ptr.ChangeElementType!T dynCast(T, Ptr)(ref scope Ptr ptr)
if(    isIntrusive!T
    && isIntrusivePtr!Ptr && !is(Ptr == shared) && !Ptr.isWeak
    && isClassOrInterface!T && __traits(getLinkage, T) == "D"
    && isClassOrInterface!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    static assert(isCopyConstructable!(Ptr, UnqualSmartPtr!Ptr));

    if(auto element = dynCastElement!T(ptr._element)){
        ptr._control.add!false;
        return typeof(return)(element, Forward.init);
    }

    return typeof(return).init;
}

/// ditto
public UnqualSmartPtr!Ptr.ChangeElementType!T dynCast(T, Ptr)(scope Ptr ptr)
if(    isIntrusive!T
    && isIntrusivePtr!Ptr && !is(Ptr == shared) && !Ptr.isWeak
    && isClassOrInterface!T && __traits(getLinkage, T) == "D"
    && isClassOrInterface!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    static assert(isMoveConstructable!(Ptr, UnqualSmartPtr!Ptr));

    return dynCastMove(ptr);
}

/// ditto
public UnqualSmartPtr!Ptr.ChangeElementType!T dynCastMove(T, Ptr)(scope auto ref Ptr ptr)
if(    isIntrusive!T
    && isIntrusivePtr!Ptr && !is(Ptr == shared) && !Ptr.isWeak
    && isClassOrInterface!T && __traits(getLinkage, T) == "D"
    && isClassOrInterface!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    static assert(isMoveConstructable!(Ptr, UnqualSmartPtr!Ptr));

    if(auto element = dynCastElement!T(ptr._element)){
        ()@trusted{
            ptr._const_reset();
        }();
        return typeof(return)(element, Forward.init);
    }

    return typeof(return).init;
}


///
pure nothrow @safe @nogc unittest{
    static class Base{
        ControlBlock!(int, int) c;
    }
    static class Foo : Base{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Bar : Foo{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }

    static class Zee : Base{
    }

    {
        IntrusivePtr!(const Foo) foo = IntrusivePtr!Bar.make(42, 3.14);
        //assert(foo.get.i == 42);

        auto bar = dynCastMove!Bar(foo);
        assert(bar != null);
        //assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == IntrusivePtr!(const Bar)));

        auto zee = dynCastMove!Zee(bar);
        assert(zee == null);
        static assert(is(typeof(zee) == IntrusivePtr!(const Zee)));
    }

    {
        IntrusivePtr!(const Foo) foo = IntrusivePtr!Bar.make(42, 3.14);
        //assert(foo.get.i == 42);

        auto bar = dynCastMove!Bar(foo);
        assert(bar != null);
        assert(foo == null);
        //assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == IntrusivePtr!(const Bar)));

        auto zee = dynCastMove!Zee(bar);
        assert(bar != null);
        assert(zee == null);
        static assert(is(typeof(zee) == IntrusivePtr!(const Zee)));
    }
}



/**
    Return `shared IntrusivePtr` pointing to same managed object like parameter `ptr`.

    Type of parameter `ptr` must be `IntrusivePtr` with `shared(ControlType)` and `shared`/`immutable` `ElementType` .
*/
public shared(Ptr) share(Ptr)(scope auto ref Ptr ptr)
if(isIntrusivePtr!Ptr){
    import core.lifetime : forward;
    static if(is(Ptr == shared)){
        return forward!ptr;
    }
    else{
        static assert(is(GetControlType!Ptr == shared) || is(GetControlType!Ptr == immutable),
            "`IntrusivePtr` has not shared ref counter `ControlType`."
        );

        static assert(is(GetElementType!Ptr == shared) || is(GetElementType!Ptr == immutable),
            "`IntrusivePtr` has not shared/immutable `ElementType`."
        );

        return typeof(return)(forward!ptr, Forward.init);
    }
}

///
nothrow @nogc unittest{
    static struct Foo{
        ControlBlock!(int, int) c;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    {
        auto x = IntrusivePtr!(shared Foo).make(123);
        assert(x.useCount == 1);

        shared s1 = share(x);
        assert(x.useCount == 2);


        import core.lifetime : move;
        shared s2 = share(x.move);
        assert(x == null);
        assert(s2.useCount == 2);
        assert(s2.load.get.i == 123);

    }

    {
        auto x = IntrusivePtr!(Foo).make(123);
        assert(x.useCount == 1);

        ///error `shared IntrusivePtr` need shared `ControlType` and shared `ElementType`.
        //shared s1 = share(x);

    }

}


/**
    Create `IntrusivePtr` instance from class reference `Elm` or struct pointer element `Elm`.

    `Elm` was created by `IntrusivePtr.make` or `IntrusivePtr.alloc`.
*/
auto intrusivePtr(Elm)(Elm elm)
if(is(Elm == class) && isIntrusive!Elm){
    import std.traits : isMutable;
    static assert(isMutable!(IntrusiveControlBlock!Elm), "control block for intrusive parameter `elm` for function `intrusivePtr` must be mutable");

    auto result = IntrusivePtr!Elm(elm, Forward.init);
    result._control.add!false;
    return result;
}

/// ditto
auto intrusivePtr(Ptr : Elm*, Elm)(Ptr elm)
if(is(Elm == struct) && isIntrusive!Elm){
    import std.traits : isMutable;
    static assert(isMutable!(IntrusiveControlBlock!Elm), "control block for intrusive parameter `elm` for function `intrusivePtr` must be mutable");

    auto result = IntrusivePtr!Elm(elm, Forward.init);
    result._control.add!false;
    return result;
}

///
unittest{
    static class Foo{
        private ControlBlock!int control;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }
    static struct Bar{
        private ControlBlock!int control;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    {
        auto i = IntrusivePtr!Foo.make(42);
        assert(i.useCount == 1);

        Foo foo = i.get;

        auto i2 = intrusivePtr(foo);
        assert(i.useCount == 2);
    }

    {
        auto i = IntrusivePtr!Bar.make(42);
        assert(i.useCount == 1);

        Bar* bar = i.element;

        auto i2 = intrusivePtr(bar);
        assert(i.useCount == 2);
    }

}


//local traits:
private{

    //Constructable:
    template isMoveConstructable(From, To){
        import std.traits : Unqual, CopyTypeQualifiers;

        alias FromElementType = GetElementType!From;
        alias ToElementType = GetElementType!To;

        static if(is(Unqual!FromElementType == Unqual!ToElementType)){
            enum bool aliasable = is(GetElementReferenceType!From : GetElementReferenceType!To);
        }
        else static if(is(FromElementType == class) && is(ToElementType == class)){
            enum bool aliasable = true
                && is(FromElementType : ToElementType);
        }
        /+else static if(is(FromElementType == struct) && is(ToElementType == struct)){
            enum bool aliasable = false;
        }+/
        else{
            enum bool aliasable = false;
        }

        enum bool isMoveConstructable = true
            && aliasable
            && is(From.DestructorType : To.DestructorType)
            && is(GetControlType!From* : GetControlType!To*);
    }
    template isCopyConstructable(From, To){
        import std.traits : isMutable, CopyTypeQualifiers;

        enum bool isCopyConstructable = true
            && isMoveConstructable!(From, To)
            && isMutable!(IntrusiveControlBlock!(
                GetElementType!From
            ));
    }
    template isConstructable(alias from, To){
        enum bool isConstructable = isRef!from
            ? isCopyConstructable!(typeof(from), To)
            : isMoveConstructable!(typeof(from), To);
    }

    //Assignable:
    template isMoveAssignable(From, To){
        import std.traits : isMutable;

        enum bool isMoveAssignable = true
            && isMoveConstructable!(From, To)
            && !weakLock!(From, To)
            && isMutable!To;
    }
    template isCopyAssignable(From, To){
        import std.traits : isMutable;

        enum bool isCopyAssignable = true
            && isCopyConstructable!(From, To)
            && !weakLock!(From, To)
            && isMutable!To;
    }
    template isAssignable(alias from, To){
        enum bool isAssignable = isRef!from
            ? isCopyAssignable!(typeof(from), To)
            : isMoveAssignable!(typeof(from), To);

    }
}


version(unittest){
    import btl.internal.test_allocator;

    //copy ctor
    pure nothrow @nogc unittest{


        static struct TestX(ControlType){
            ControlType control;
        }

        import std.meta : AliasSeq;
        //alias Test = long;
        static foreach(alias Test; AliasSeq!(
            TestX!(SharedControlBlock),
            //TestX!(shared SharedControlBlock)
        )){{
            alias SPtr(T) = IntrusivePtr!(T);

            //mutable:
            {
                alias Ptr = SPtr!(Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(!__traits(compiles, shared(Ptr)(ptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(ptr)));
            }

            //const:
            {
                alias Ptr = SPtr!(const Test);
                Ptr ptr;
                static assert(!__traits(compiles, Ptr(ptr)));
                static assert(!__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(!__traits(compiles, shared(Ptr)(ptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(ptr)));
            }

            //immutable:
            {
                alias Ptr = SPtr!(immutable Test);
                Ptr ptr;
                static assert(!__traits(compiles, Ptr(ptr)));
                static assert(!__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(!__traits(compiles, shared(Ptr)(ptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(ptr)));
            }


            //shared:
            {
                alias Ptr = SPtr!(shared Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(__traits(compiles, shared(Ptr)(ptr)));
                static assert(__traits(compiles, const(shared(Ptr))(ptr)));
            }


            //const shared:
            {
                alias Ptr = SPtr!(const shared Test);
                Ptr ptr;
                static assert(!__traits(compiles, Ptr(ptr)));
                static assert(!__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(!__traits(compiles, shared(Ptr)(ptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(ptr)));
            }

            static foreach(alias T; AliasSeq!(
                Test,
                const Test,
                shared Test,
                const shared Test,
                immutable Test,
            )){{
                alias Ptr = SPtr!T;

                const(Ptr) cptr;
                static assert(!__traits(compiles, Ptr(cptr)));
                static assert(!__traits(compiles, const(Ptr)(cptr)));
                static assert(!__traits(compiles, immutable(Ptr)(cptr)));
                static assert(!__traits(compiles, shared(Ptr)(cptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(cptr)));

                immutable(Ptr) iptr;
                static assert(!__traits(compiles, Ptr(iptr)));
                static assert(!__traits(compiles, const(Ptr)(iptr)));
                static assert(!__traits(compiles, immutable(Ptr)(iptr)));
                static assert(!__traits(compiles, shared(Ptr)(iptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(iptr)));

                shared(Ptr) sptr;
                static assert(!__traits(compiles, Ptr(sptr)));
                static assert(!__traits(compiles, const(Ptr)(sptr)));
                static assert(!__traits(compiles, immutable(Ptr)(sptr)));
                static assert(!__traits(compiles, shared(Ptr)(sptr)));          //need load
                static assert(!__traits(compiles, const shared Ptr(sptr)));     //need load

                shared(const(Ptr)) scptr;
                static assert(!__traits(compiles, Ptr(scptr)));
                static assert(!__traits(compiles, const(Ptr)(scptr)));
                static assert(!__traits(compiles, immutable(Ptr)(scptr)));
                static assert(!__traits(compiles, shared(Ptr)(scptr)));         //need load
                static assert(!__traits(compiles, const(shared(Ptr))(scptr)));  //need load

            }}

        }}
    }

    //this(typeof(null))
    pure nothrow @safe @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
        }

        {
            IntrusivePtr!Foo x = null;

            assert(x == null);
            assert(x == IntrusivePtr!Foo.init);

        }

    }


    //opAssign(IntrusivePtr)
    pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo px1 = IntrusivePtr!Foo.make(1);
            IntrusivePtr!Foo px2 = IntrusivePtr!Foo.make(2);

            assert(px2.useCount == 1);
            px1 = px2;
            assert(px1.get.i == 2);
            assert(px2.useCount == 2);
        }



        {
            IntrusivePtr!(Foo) px = IntrusivePtr!(Foo).make(1);
            IntrusivePtr!(const Foo) pcx = IntrusivePtr!(Foo).make(2);

            assert(px.useCount == 1);
            pcx = px;
            assert(pcx.get.i == 1);
            assert(pcx.useCount == 2);

        }


        /+{
            const IntrusivePtr!(Foo) cpx = IntrusivePtr!(Foo).make(1);
            IntrusivePtr!(const Foo) pcx = IntrusivePtr!(Foo).make(2);

            assert(pcx.useCount == 1);
            pcx = cpx;
            assert(pcx.get.i == 1);
            assert(pcx.useCount == 2);

        }+/

        /+{
            IntrusivePtr!(immutable Foo) pix = IntrusivePtr!(immutable Foo).make(123);
            IntrusivePtr!(const Foo) pcx = IntrusivePtr!(Foo).make(2);

            assert(pix.useCount == 1);
            pcx = pix;
            assert(pcx.get.i == 123);
            assert(pcx.useCount == 2);

        }+/
    }

    //opAssign(null)
    nothrow @safe @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x == null);
        }

        {
            IntrusivePtr!(shared Foo) x = IntrusivePtr!(shared Foo).make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x == null);
        }

        import btl.internal.mutex : supportMutex;
        static if(supportMutex){
            shared IntrusivePtr!(shared Foo) x = IntrusivePtr!(shared Foo).make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x.load == null);
        }
    }

    //useCount
    pure nothrow @safe @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }


        IntrusivePtr!Foo x = null;

        assert(x.useCount == 0);

        x = IntrusivePtr!Foo.make(123);
        assert(x.useCount == 1);

        auto y = x;
        assert(x.useCount == 2);

        auto w1 = x.weak;    //weak ptr
        assert(x.useCount == 2);

        IntrusivePtr!Foo.WeakType w2 = x;   //weak ptr
        assert(x.useCount == 2);

        y = null;
        assert(x.useCount == 1);

        x = null;
        assert(x.useCount == 0);
        assert(w1.useCount == 0);
    }

    //weakCount
    pure nothrow @safe @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        IntrusivePtr!Foo x = null;
        assert(x.useCount == 0);
        assert(x.weakCount == 0);

        x = IntrusivePtr!Foo.make(123);
        assert(x.useCount == 1);
        assert(x.weakCount == 0);

        auto w = x.weak();
        assert(x.useCount == 1);
        assert(x.weakCount == 1);
    }

    // store:
    nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        //null store:
        {
            shared x = IntrusivePtr!(shared Foo).make(123);
            assert(x.load.get.i == 123);

            x.store(null);
            assert(x.useCount == 0);
            assert(x.load == null);
        }

        //rvalue store:
        {
            shared x = IntrusivePtr!(shared Foo).make(123);
            assert(x.load.get.i == 123);

            x.store(IntrusivePtr!(shared Foo).make(42));
            assert(x.load.get.i == 42);
        }

        //lvalue store:
        {
            shared x = IntrusivePtr!(shared Foo).make(123);
            auto y = IntrusivePtr!(shared Foo).make(42);

            assert(x.load.get.i == 123);
            assert(y.load.get.i == 42);

            x.store(y);
            assert(x.load.get.i == 42);
            assert(x.useCount == 2);
        }
    }

    //load:
    nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        shared IntrusivePtr!(shared Foo) x = IntrusivePtr!(shared Foo).make(123);

        import btl.internal.mutex : supportMutex;
        static if(supportMutex){
            IntrusivePtr!(shared Foo) y = x.load();
            assert(y.useCount == 2);

            assert(y.get.i == 123);
        }

    }

    //exchange
    nothrow @nogc unittest{
        import core.lifetime : move;

        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        //lvalue exchange
        {
            shared x = IntrusivePtr!(shared Foo).make(123);
            auto y = IntrusivePtr!(shared Foo).make(42);

            auto z = x.exchange(y);

            assert(x.load.get.i == 42);
            assert(y.get.i == 42);
            assert(z.get.i == 123);
        }

        //rvalue exchange
        {
            shared x = IntrusivePtr!(shared Foo).make(123);
            auto y = IntrusivePtr!(shared Foo).make(42);

            auto z = x.exchange(y.move);

            assert(x.load.get.i == 42);
            assert(y == null);
            assert(z.get.i == 123);
        }

        //null exchange (same as move)
        {
            shared x = IntrusivePtr!(shared Foo).make(123);

            auto z = x.exchange(null);

            assert(x.load == null);
            assert(z.get.i == 123);
        }

        //swap:
        {
            shared x = IntrusivePtr!(shared Foo).make(123);
            auto y = IntrusivePtr!(shared Foo).make(42);

            //opAssign is same as store
            y = x.exchange(y.move);

            assert(x.load.get.i == 42);
            assert(y.get.i == 123);
        }

    }


    //compareExchange
    pure nothrow @nogc unittest{
        static class Foo{
            long i;
            ControlBlock!(int, int) c;

            this(long i)pure nothrow @safe @nogc{
                this.i = i;
            }

            bool opEquals(this This)(long i)const @trusted{
                import std.traits : Unqual;
                auto self = cast(Unqual!This)this;
                return (self.i == i);
            }


        }
        alias Type = Foo;
        static foreach(enum bool weak; [true, false]){
            //fail
            {
                IntrusivePtr!Type a = IntrusivePtr!Type.make(123);
                IntrusivePtr!Type b = IntrusivePtr!Type.make(42);
                IntrusivePtr!Type c = IntrusivePtr!Type.make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                assert(*a == 123);
                assert(*b == 123);
                assert(*c == 666);

            }

            //success
            {
                IntrusivePtr!Type a = IntrusivePtr!Type.make(123);
                IntrusivePtr!Type b = a;
                IntrusivePtr!Type c = IntrusivePtr!Type.make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                assert(*a == 666);
                assert(*b == 123);
                assert(*c == 666);
            }

            //shared fail
            {
                shared IntrusivePtr!(shared Type) a = IntrusivePtr!(shared Type).make(123);
                IntrusivePtr!(shared Type) b = IntrusivePtr!(shared Type).make(42);
                IntrusivePtr!(shared Type) c = IntrusivePtr!(shared Type).make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                auto tmp = a.exchange(null);
                assert(*tmp == 123);
                assert(*b == 123);
                assert(*c == 666);
            }

            //shared success
            {
                IntrusivePtr!(shared Type) b = IntrusivePtr!(shared Type).make(123);
                shared IntrusivePtr!(shared Type) a = b;
                IntrusivePtr!(shared Type) c = IntrusivePtr!(shared Type).make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                auto tmp = a.exchange(null);
                assert(*tmp == 666);
                assert(*b == 123);
                assert(*c == 666);
            }
        }

    }

    //lock
    nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);

            auto w = x.weak;    //weak ptr

            IntrusivePtr!Foo y = w.lock;

            assert(x == y);
            assert(x.useCount == 2);
            assert(y.get.i == 123);
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);

            auto w = x.weak;    //weak ptr

            assert(w.expired == false);

            x = IntrusivePtr!Foo.make(321);

            assert(w.expired == true);

            IntrusivePtr!Foo y = w.lock;

            assert(y == null);
        }
        {
            shared IntrusivePtr!(shared Foo) x = IntrusivePtr!(shared Foo).make(123);

            shared IntrusivePtr!(shared Foo).WeakType w = x.load.weak;    //weak ptr

            assert(w.expired == false);

            x = IntrusivePtr!(shared Foo).make(321);

            assert(w.expired == true);

            IntrusivePtr!(shared Foo) y = w.load.lock;

            assert(y == null);
        }
    }

    //expired
    nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);

            auto wx = x.weak;   //weak pointer

            assert(wx.expired == false);

            x = null;

            assert(wx.expired == true);
        }
    }

    //make
    pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo a = IntrusivePtr!Foo.make();
            assert(a.get.i == 0);

            IntrusivePtr!(const Foo) b = IntrusivePtr!Foo.make(2);
            assert(b.get.i == 2);
        }

        {
            static struct Struct{
                ControlBlock!int c;
                int i = 7;

                this(int i)pure nothrow @safe @nogc{
                    this.i = i;
                }
            }

            IntrusivePtr!Struct s1 = IntrusivePtr!Struct.make();
            assert(s1.get.i == 7);

            IntrusivePtr!Struct s2 = IntrusivePtr!Struct.make(123);
            assert(s2.get.i == 123);
        }
    }

    //alloc
    nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }

            ~this()nothrow @safe @nogc{}
        }

        {
            TestAllocator allocator;

            {
                IntrusivePtr!Foo a = IntrusivePtr!Foo.alloc(&allocator);
                assert(a.get.i == 0);

                IntrusivePtr!(const Foo) b = IntrusivePtr!Foo.alloc(&allocator, 2);
                assert(b.get.i == 2);
            }

            {
                static struct Struct{
                    ControlBlock!(int) c;
                    int i = 7;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                    ~this()nothrow @safe @nogc{}
                }

                IntrusivePtr!Struct s1 = IntrusivePtr!Struct.alloc(allocator);
                assert(s1.get.i == 7);

                IntrusivePtr!Struct s2 = IntrusivePtr!Struct.alloc(allocator, 123);
                assert(s2.get.i == 123);
            }

        }
    }

    //alloc
    unittest{
        import std.experimental.allocator : allocatorObject;

        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }

            ~this(){
                if(false)
                    auto a = allocatorObject(Mallocator.instance);
            }
        }

        {

            auto a = allocatorObject(Mallocator.instance);
            {
                auto x = IntrusivePtr!Foo.alloc(a);
                assert(x.get.i == 0);

                auto y = IntrusivePtr!Foo.alloc(a, 2);
                assert(y.get.i == 2);
            }

            {
                static struct Struct{
                    ControlBlock!(int) c;
                    int i = 7;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }

                    ~this(){
                        if(false)
                            auto a = allocatorObject(Mallocator.instance);
                    }
                }

                auto s1 = IntrusivePtr!Struct.alloc(a);
                assert(s1.get.i == 7);

                auto s2 = IntrusivePtr!Struct.alloc(a, 123);
                assert(s2.get.i == 123);
            }

        }
    }

    //ctor
    pure nothrow @nogc @safe unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
            assert(x.useCount == 1);

            IntrusivePtr!Foo a = x;         //lvalue copy ctor
            assert(a == x);

            const IntrusivePtr!Foo b = x;   //lvalue copy ctor
            assert(b == x);

            IntrusivePtr!Foo c = x; //lvalue ctor
            assert(c == x);

            const IntrusivePtr!Foo d = a;   //lvalue ctor
            assert(d == x);

            assert(x.useCount == 5);
        }

        {
            import core.lifetime : move;
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
            assert(x.useCount == 1);

            IntrusivePtr!Foo a = move(x);        //rvalue copy ctor
            assert(a.useCount == 1);

            const IntrusivePtr!Foo b = move(a);  //rvalue copy ctor
            assert(b.useCount == 1);

            /+IntrusivePtr!(const Foo) c = b.load;  //rvalue ctor
            assert(c.useCount == 2);

            const IntrusivePtr!Foo d = move(c);  //rvalue ctor
            assert(d.useCount == 2);+/
        }

    }

    //weak
    pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
        assert(x.useCount == 1);
        auto wx = x.weak;   //weak pointer
        assert(wx.expired == false);
        assert(wx.lock.get.i == 123);
        assert(wx.useCount == 1);
        x = null;
        assert(wx.expired == true);
        assert(wx.useCount == 0);

    }

    //operator *
    pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;
            alias i this;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
        assert(*x == 123);
        ((*x).i = 321);
        assert(*x == 321);
        const y = x;
        assert(*y == 321);
        assert(*x == 321);
        static assert(is(typeof(*y) == const Foo));
    }

    //get
    pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
        assert(x.get.i == 123);
        x.get.i = 321;
        assert(x.get.i == 321);
        const y = x;
        assert(y.get.i == 321);
        assert(x.get.i == 321);
        static assert(is(typeof(y.get) == const Foo));
    }

    //element
    pure nothrow @nogc unittest{

        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
            assert(x.element.i == 123);

            x.get.i = 321;
            assert(x.element.i == 321);

            const y = x;
            assert(y.element.i == 321);
            assert(x.element.i == 321);

            static assert(is(typeof(y.element) == const(Foo)*));
        }

        {
            auto s = IntrusivePtr!Foo.make(42);
            const w = s.weak;

            assert(w.element.i == 42);

            s = null;
            assert(w.element is null);
        }

        {
            auto s = IntrusivePtr!Foo.make(42);
            auto w = s.weak;

            scope const p = w.element;

            s = null;
            assert(w.element is null);

            assert(p !is null); //p is dangling pointer!
        }
    }

    //opCast bool
    @safe pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
        assert(cast(bool)x);    //explicit cast
        assert(x);              //implicit cast
        x = null;
        assert(!cast(bool)x);   //explicit cast
        assert(!x);             //implicit cast
    }

    //opCast IntrusivePtr
    /+TODO
    @safe pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;
            alias i this;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
        assert(x.useCount == 1
        );
        auto y = cast(IntrusivePtr!(const Foo))x;
        //debug assert(x.useCount == 2, x.useCount.to!string);
        assert(x.useCount == 2);


        auto z = cast(const IntrusivePtr!Foo)x;
        assert(x.useCount == 3);

        auto u = cast(const IntrusivePtr!(const Foo))x;
        assert(x.useCount == 4);
    }
    +/

    //opEquals IntrusivePtr
    pure @safe nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(0);
            assert(x != null);
            x = null;
            assert(x == null);
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
            IntrusivePtr!Foo y = IntrusivePtr!Foo.make(123);
            assert(x == x);
            assert(y == y);
            assert(x != y);
        }

        {
            IntrusivePtr!Foo x;
            IntrusivePtr!(const Foo) y;
            assert(x == x);
            assert(y == y);
            assert(x == y);
        }
    }

    //opEquals IntrusivePtr
    pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
            IntrusivePtr!Foo y = IntrusivePtr!Foo.make(123);
            assert(x == x.element);
            assert(y.element == y);
            assert(x != y.element);
        }
    }

    //opCmp
    pure nothrow @safe @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            const a = IntrusivePtr!Foo.make(42);
            const b = IntrusivePtr!Foo.make(123);
            const n = IntrusivePtr!Foo.init;

            assert(a <= a);
            assert(a >= a);

            assert((a < b) == !(a >= b));
            assert((a > b) == !(a <= b));

            assert(a > n);
            assert(a > null);

            assert(n < a);
            assert(null < a);
        }
    }

    //opCmp
    pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            const a = IntrusivePtr!Foo.make(42);
            const b = IntrusivePtr!Foo.make(123);

            assert(a <= a.element);
            assert(a.element >= a);

            assert((a < b.element) == !(a.element >= b));
            assert((a > b.element) == !(a.element <= b));
        }
    }

    //toHash
    pure nothrow @safe @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo x = IntrusivePtr!Foo.make(123);
            IntrusivePtr!Foo y = IntrusivePtr!Foo.make(123);
            assert(x.toHash == x.toHash);
            assert(y.toHash == y.toHash);
            assert(x.toHash != y.toHash);
            IntrusivePtr!(const Foo) z = x;
            assert(x.toHash == z.toHash);
        }
        {
            IntrusivePtr!Foo x;
            IntrusivePtr!(const Foo) y;
            assert(x.toHash == x.toHash);
            assert(y.toHash == y.toHash);
            assert(x.toHash == y.toHash);
        }
    }

    //proxySwap
    pure nothrow @nogc unittest{
        static struct Foo{
            ControlBlock!(int, int) c;
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {
            IntrusivePtr!Foo a = IntrusivePtr!Foo.make(1);
            IntrusivePtr!Foo b = IntrusivePtr!Foo.make(2);
            a.proxySwap(b);
            assert(a != null);
            assert(b != null);
            assert(a.get.i == 2);
            assert(b.get.i == 1);
            import std.algorithm : swap;
            swap(a, b);
            assert(a.get.i == 1);
            assert(b.get.i == 2);
            assert(a.useCount == 1);
            assert(b.useCount == 1);
        }
    }
}


version(unittest){
    struct Bar{
        ControlBlock!int cb;
    }
    struct Foo{
        IntrusivePtr!Bar bar;
    }
}




//test strong ptr -> weak ptr move ctor
unittest{
    static struct Foo{
        ControlBlock!(int, int) c;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    {
        import core.lifetime : move;

        auto a = IntrusivePtr!Foo.make(1);
        auto b = a;
        assert(a.useCount == 2);
        assert(a.weakCount == 0);

        IntrusivePtr!Foo.WeakType x = move(a);
        assert(b.useCount == 1);
        assert(b.weakCount == 1);
    }
}

//test strong ptr -> weak ptr assign
unittest{
    static struct Foo{
        ControlBlock!(int, int) c;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    {
        import core.lifetime : move;

        auto a = IntrusivePtr!Foo.make(1);
        auto b = IntrusivePtr!Foo.make(2);

        {
            IntrusivePtr!Foo.WeakType x = IntrusivePtr!Foo(a);
            assert(a.useCount == 1);
            assert(a.weakCount == 1);

            x = IntrusivePtr!Foo(b);
            assert(a.useCount == 1);
            assert(a.weakCount == 0);

            assert(b.useCount == 1);
            assert(b.weakCount == 1);
        }
        {
            IntrusivePtr!Foo.WeakType x = a;
            assert(a.useCount == 1);
            assert(a.weakCount == 1);

            IntrusivePtr!Foo.WeakType y = b;
            assert(b.useCount == 1);
            assert(b.weakCount == 1);

            x = y;
            assert(a.useCount == 1);
            assert(a.weakCount == 0);

            assert(b.useCount == 1);
            assert(b.weakCount == 2);


        }
    }
}

//compare strong and weak ptr
unittest{
    static struct Foo{
        ControlBlock!(int, int) c;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    auto a = IntrusivePtr!Foo.make(1);
    auto b = a.weak;
    assert(a == b);

}

//self opAssign
unittest{
    static struct Foo{
        ControlBlock!(int, int) c;
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    auto a = IntrusivePtr!Foo.make(1);
    a = a;
}

