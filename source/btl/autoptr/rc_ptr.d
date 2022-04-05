/**
    Implementation of non aliasable reference counted pointer `RcPtr` (similar to c++ `std::shared_ptr` without aliasing).

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/basic_string, Adam Búš)
*/
module btl.autoptr.rc_ptr;

import btl.internal.allocator;
import btl.internal.traits;
import btl.internal.gc;

import btl.autoptr.common;


/**
    Check if type `T` is `RcPtr`.
*/
public template isRcPtr(T){
    import std.traits : isInstanceOf;

    enum bool isRcPtr = isInstanceOf!(RcPtr, T);
}

///
unittest{
    static assert(!isRcPtr!long);
    static assert(!isRcPtr!(void*));

    static assert(isRcPtr!(RcPtr!long));
    static assert(isRcPtr!(RcPtr!long.WeakType));
}



/**
    Implementation of a ref counted pointer without support for aliasing (smaller size of pointer).

    `RcPtr` retains shared ownership of an object through a pointer.
        
    Several ref counted pointer objects may own the same object.

    The object is destroyed and its memory deallocated when either of the following happens:

        1. the last remaining ref counted pointer owning the object is destroyed.

        2. the last remaining ref counted pointer owning the object is assigned another pointer via various methods like `opAssign` and `store`.

    The object is destroyed using destructor of type `_Type`.

    A `RcPtr` can not share ownership of an object while storing a pointer to another object (use `SharedPtr` for that).
    The stored pointer is the one accessed by `get()`, the dereference and the comparison operators.

    A `RcPtr` may also own no objects, in which case it is called empty.

    If template parameter `_ControlType` is `shared`  then all member functions (including copy constructor and copy assignment)
    can be called by multiple threads on different instances of `RcPtr` without additional synchronization even if these instances are copies and share ownership of the same object.

    If multiple threads of execution access the same `RcPtr` (`shared RcPtr`) then only some methods can be called (`load`, `store`, `exchange`, `compareExchange`, `useCount`).

    Template parameters:

        `_Type` type of managed object

        `_DestructorType` function pointer with attributes of destructor, to get attributes of destructor from type use `btl.autoptr.common.DestructorType!T`. Destructor of type `_Type` must be compatible with `_DestructorType`

        `_ControlType` represent type of counter, must by of type `btl.autoptr.common.ControlBlock`. if is shared then ref counting is atomic.

        `_weakPtr` if `true` then `RcPtr` represent weak ptr

*/
public template RcPtr(
    _Type,
    _DestructorType = DestructorType!_Type,
    _ControlType = ControlBlockDeduction!(_Type, SharedControlBlock),
    bool _weakPtr = false
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){

    static assert(_ControlType.hasSharedCounter || is(_ControlType == immutable),
        "_ControlType must be `ControlBlock` with shared counter or `btl.autoptr.common.ControlBlock` must be immutable."
    );

    static assert(!_weakPtr || _ControlType.hasWeakCounter,
        "weak pointer must have control block with weak counter"
    );

    static if (is(_Type == class) || is(_Type == interface) || is(_Type == struct) || is(_Type == union))
        static assert(!__traits(isNested, _Type),
            "RcPtr does not support nested types."
        );

    static assert(is(DestructorType!void : _DestructorType),
        _Type.stringof ~ " wrong DestructorType " ~ DestructorType!void.stringof ~
        " : " ~ _DestructorType.stringof
    );

    /*
    static assert(is(DestructorType!_Type : _DestructorType),
        "destructor of type '" ~ _Type.stringof ~
        "' doesn't support specified finalizer " ~ _DestructorType.stringof
    );
    */

    void check_dtor()(){

        static assert(!isIntrusive!_Type);

        static assert(is(DestructorType!_Type : _DestructorType),
            "destructor of type '" ~ _Type.stringof ~
            "' doesn't support specified finalizer " ~ _DestructorType.stringof
        );
    }

    import std.meta : AliasSeq;
    import std.range : ElementEncodingType;
    import std.traits: Unqual, Unconst, CopyTypeQualifiers, CopyConstness,
        hasIndirections, hasElaborateDestructor,
        isMutable, isAbstractClass, isDynamicArray, isStaticArray, isCallable, Select, isArray;

    import core.atomic : MemoryOrder;
    import core.lifetime : forward;


    enum bool hasWeakCounter = _ControlType.hasWeakCounter;

    enum bool hasSharedCounter = _ControlType.hasSharedCounter;

    enum bool referenceElementType = isClassOrInterface!_Type || isDynamicArray!_Type;


    enum bool _isLockFree = !isDynamicArray!_Type;

    struct RcPtr{

        /**
            Type of element managed by `RcPtr`.
        */
        public alias ElementType = _Type;


        /**
            Type of destructor (`void function(void*)@attributes`).
        */
        public alias DestructorType = _DestructorType;


        /**
            Type of control block.
        */
        public alias ControlType = _ControlType;


        /**
            `true` if `RcPtr` is weak ptr.
        */
        public alias isWeak = _weakPtr;


        /**
            Same as `ElementType*` or `ElementType` if is class/interface/slice.
        */
        public alias ElementReferenceType = ElementReferenceTypeImpl!ElementType;


        /**
            Weak pointer

            `RcPtr.WeakType` is a smart pointer that holds a non-owning ("weak") reference to an object that is managed by `RcPtr`.
            It must be converted to `RcPtr` in order to access the referenced object.

            `RcPtr.WeakType` models temporary ownership: when an object needs to be accessed only if it exists, and it may be deleted at any time by someone else,
            `RcPtr.WeakType` is used to track the object, and it is converted to `RcPtr` to assume temporary ownership.
            If the original `RcPtr` is destroyed at this time, the object's lifetime is extended until the temporary `RcPtr` is destroyed as well.

            Another use for `RcPtr.WeakType` is to break reference cycles formed by objects managed by `RcPtr`.
            If such cycle is orphaned (i,e. there are no outside shared pointers into the cycle), the `RcPtr` reference counts cannot reach zero and the memory is leaked.
            To prevent this, one of the pointers in the cycle can be made weak.
        */
        static if(hasWeakCounter)
            public alias WeakType = RcPtr!(
                _Type,
                _DestructorType,
                _ControlType,
                true
            );
        else
            public alias WeakType = void;


        /**
            Type of non weak ptr.
        */
        public alias SharedType = RcPtr!(
            _Type,
            _DestructorType,
            _ControlType,
            false
        );


        /**
            `true` if shared `RcPtr` has lock free operations `store`, `load`, `exchange`, `compareExchange`, otherwise 'false'
        */
        public alias isLockFree = _isLockFree;

        static if(isLockFree)
            static assert(ElementReferenceType.sizeof == size_t.sizeof);



        /**
            Destructor

            If `this` owns an object and it is the last `RcPtr` owning it, the object is destroyed.
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

        //
        package this(C, Elm, this This)(C* control, Elm element)pure nothrow @safe @nogc
        if(true
            && is(Elm : GetElementReferenceType!This) 
            && is(C : GetControlType!This) 
            && !is(Unqual!Elm == typeof(null))
        ){
            assert(control !is null);
            assert((control is null) == (element is null));

            this(element, Forward.init);
            control.add!isWeak;
        }


        /**
            Forward constructor (merge move and copy constructor).
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs, Forward)@trusted
        if(    isRcPtr!Rhs
            && isConstructable!(rhs, This)
            && !is(Rhs == shared)
        ){
            //lock (copy):
            static if(weakLock!(Rhs, This)){
                if(rhs._element !is null && rhs._control.add_shared_if_exists())
                    this._element = rhs._element;
                /+else
                    this._element = null;+/
            }
            //copy
            else static if(isRef!rhs){
                static assert(isCopyConstructable!(Rhs, This));

                if(rhs._element is null)
                    this(null);
                else
                    this(rhs._control, rhs._element);
            }
            //move
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
            Constructs a `RcPtr` without managed object. Same as `RcPtr.init`

            Examples:
                --------------------
                RcPtr!long x = null;

                assert(x == null);
                assert(x == RcPtr!long.init);
                --------------------
        */
        public this(this This)(typeof(null) nil)pure nothrow @safe @nogc{
        }



        /**
            Constructs a `RcPtr` which shares ownership of the object managed by `rhs`.

            If rhs manages no object, this manages no object too.
            If rhs if rvalue then ownership is moved.
            The template overload doesn't participate in overload resolution if ElementType of `typeof(rhs)` is not implicitly convertible to `ElementType`.
            If rhs if `WeakType` then this ctor is equivalent to `this(rhs.lock())`.

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);
                    assert(x.useCount == 1);

                    RcPtr!long a = x;         //lvalue copy ctor
                    assert(a == x);

                    const RcPtr!long b = x;   //lvalue copy ctor
                    assert(b == x);

                    RcPtr!(const long) c = x; //lvalue ctor
                    assert(c == x);

                    const RcPtr!long d = b;   //lvalue ctor
                    assert(d == x);

                    assert(x.useCount == 5);
                }

                {
                    import core.lifetime : move;
                    RcPtr!long x = RcPtr!long.make(123);
                    assert(x.useCount == 1);

                    RcPtr!long a = move(x);        //rvalue copy ctor
                    assert(a.useCount == 1);

                    const RcPtr!long b = move(a);  //rvalue copy ctor
                    assert(b.useCount == 1);

                    RcPtr!(const long) c = b.load;  //rvalue ctor
                    assert(c.useCount == 2);

                    const RcPtr!long d = move(c);  //rvalue ctor
                    assert(d.useCount == 2);
                }

                {
                    import core.lifetime : move;
                    auto u = UniquePtr!(long, SharedControlBlock).make(123);

                    RcPtr!long s = move(u);        //rvalue copy ctor
                    assert(s != null);
                    assert(s.useCount == 1);

                    RcPtr!long s2 = UniquePtr!(long, SharedControlBlock).init;
                    assert(s2 == null);
                }
                --------------------
        */
        public this(Rhs, this This)(scope auto ref Rhs rhs)@trusted
        if(    isRcPtr!Rhs
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
                {
                    RcPtr!long x = RcPtr!long.make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x == null);
                }

                {
                    RcPtr!(shared long) x = RcPtr!(shared long).make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x == null);
                }

                {
                    shared RcPtr!(long) x = RcPtr!(shared long).make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x == null);
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
            If `rhs` is rvalue then move-assigns a `RcPtr` from `rhs`

            Examples:
                --------------------
                {
                    RcPtr!long px1 = RcPtr!long.make(1);
                    RcPtr!long px2 = RcPtr!long.make(2);

                    assert(px2.useCount == 1);
                    px1 = px2;
                    assert(*px1 == 2);
                    assert(px2.useCount == 2);
                }


                {
                    RcPtr!long px = RcPtr!long.make(1);
                    RcPtr!(const long) pcx = RcPtr!long.make(2);

                    assert(px.useCount == 1);
                    pcx = px;
                    assert(*pcx == 1);
                    assert(pcx.useCount == 2);

                }


                {
                    const RcPtr!long cpx = RcPtr!long.make(1);
                    RcPtr!(const long) pcx = RcPtr!long.make(2);

                    assert(pcx.useCount == 1);
                    pcx = cpx;
                    assert(*pcx == 1);
                    assert(pcx.useCount == 2);

                }

                {
                    RcPtr!(immutable long) pix = RcPtr!(immutable long).make(123);
                    RcPtr!(const long) pcx = RcPtr!long.make(2);

                    assert(pix.useCount == 1);
                    pcx = pix;
                    assert(*pcx == 123);
                    assert(pcx.useCount == 2);

                }
                --------------------
        */
        public void opAssign(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(scope auto ref Rhs desired)scope
        if(    isRcPtr!Rhs
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
            Constructs an object of type `ElementType` and wraps it in a `RcPtr` using args as the parameter list for the constructor of `ElementType`.

            The object is constructed as if by the expression `emplace!ElementType(_payload, forward!args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof` in order to use one allocation for both the control block and the `ElementType` object.

            Examples:
                --------------------
                {
                    RcPtr!long a = RcPtr!long.make();
                    assert(a.get == 0);

                    RcPtr!(const long) b = RcPtr!long.make(2);
                    assert(b.get == 2);
                }

                {
                    static struct Struct{
                        int i = 7;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    RcPtr!Struct s1 = RcPtr!Struct.make();
                    assert(s1.get.i == 7);

                    RcPtr!Struct s2 = RcPtr!Struct.make(123);
                    assert(s2.get.i == 123);
                }

                {
                    static interface Interface{
                    }
                    static class Class : Interface{
                        int i;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    RcPtr!Interface x = RcPtr!Class.make(3);
                    //assert(x.dynTo!Class.get.i == 3);
                }
                --------------------
        */
        public static auto make(AllocatorType = DefaultAllocator, bool supportGC = platformSupportGC, Args...)(auto ref Args args)
        if(!isDynamicArray!ElementType){
            check_dtor();

            alias ReturnType = RcPtr!(
                ElementType,
                .DestructorType!(
                    .DestructorType!ElementType,
                    DestructorType,
                    DestructorAllocatorType!AllocatorType
                ),
                ControlType
            );

            auto m = ReturnType.MakeEmplace!(AllocatorType, supportGC).make(AllocatorType.init, forward!(args));

            return (m is null)
                ? ReturnType.init
                : ReturnType(m.get, Forward.init);
        }


        /**
            Constructs an object of array type `ElementType` including its array elements and wraps it in a `RcPtr`.

            Parameters:
                n = Array length

                args = parameters for constructor for each array element.

            The array elements are constructed as if by the expression `emplace!ElementType(_payload, args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof * n` in order to use one allocation for both the control block and the each array element.

            Examples:
                --------------------
                auto arr = RcPtr!(long[]).make(6, -1);
                assert(arr.length == 6);
                assert(arr.get.length == 6);

                import std.algorithm : all;
                assert(arr.get.all!(x => x == -1));

                for(int i = 0; i < 6; ++i)
                    arr.get[i] = i;

                assert(arr.get == [0, 1, 2, 3, 4, 5]);
                --------------------
        */
        public static auto make(AllocatorType = DefaultAllocator, bool supportGC = platformSupportGC, Args...)(const size_t n, auto ref Args args)
        if(isDynamicArray!ElementType){
            check_dtor();

            alias ReturnType = RcPtr!(
                ElementType,
                .DestructorType!(
                    .DestructorType!ElementType,
                    DestructorType,
                    DestructorAllocatorType!AllocatorType
                ),
                ControlType
            );

            auto m = ReturnType.MakeDynamicArray!(AllocatorType, supportGC).make(AllocatorType.init, n, forward!(args));

            return (m is null)
                ? ReturnType.init
                : ReturnType(m.get, Forward.init);
        }



        /**
            Constructs an object of type `ElementType` and wraps it in a `RcPtr` using args as the parameter list for the constructor of `ElementType`.

            The object is constructed as if by the expression `emplace!ElementType(_payload, forward!args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof` in order to use one allocation for both the control block and the `ElementType` object.

            Examples:
                --------------------
                auto a = allocatorObject(Mallocator.instance);
                {
                    auto a = RcPtr!long.alloc(a);
                    assert(a.get == 0);

                    auto b = RcPtr!(const long).alloc(a, 2);
                    assert(b.get == 2);
                }

                {
                    static struct Struct{
                        int i = 7;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    auto s1 = RcPtr!Struct.alloc(a);
                    assert(s1.get.i == 7);

                    auto s2 = RcPtr!Struct.alloc(a, 123);
                    assert(s2.get.i == 123);
                }

                {
                    static interface Interface{
                    }
                    static class Class : Interface{
                        int i;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    RcPtr!Interface x = RcPtr!Class.alloc(a, 3);
                    //assert(x.dynTo!Class.get.i == 3);
                }
                --------------------
        */
        public static auto alloc(bool supportGC = platformSupportGC, AllocatorType, Args...)(AllocatorType a, auto ref Args args)
        if(!isDynamicArray!ElementType){
            check_dtor();

            alias ReturnType = RcPtr!(
                ElementType,
                .DestructorType!(
                    .DestructorType!ElementType,
                    DestructorType,
                    DestructorAllocatorType!AllocatorType
                ),
                ControlType
            );
            auto m = ReturnType.MakeEmplace!(AllocatorType, supportGC).make(forward!(a, args));

            return (m is null)
                ? ReturnType.init
                : ReturnType(m.get, Forward.init);
        }



        /**
            Constructs an object of array type `ElementType` including its array elements and wraps it in a `RcPtr`.

            Parameters:
                n = Array length

                args = parameters for constructor for each array element.

            The array elements are constructed as if by the expression `emplace!ElementType(_payload, args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof * n` in order to use one allocation for both the control block and the each array element.

            Examples:
                --------------------
                auto a = allocatorObject(Mallocator.instance);
                auto arr = RcPtr!(long[], DestructorType!(typeof(a))).alloc(a, 6, -1);
                assert(arr.length == 6);
                assert(arr.get.length == 6);

                import std.algorithm : all;
                assert(arr.get.all!(x => x == -1));

                for(int i = 0; i < 6; ++i)
                    arr.get[i] = i;

                assert(arr.get == [0, 1, 2, 3, 4, 5]);
                --------------------
        */
        public static auto alloc(bool supportGC = platformSupportGC, AllocatorType, Args...)(AllocatorType a, const size_t n, auto ref Args args)
        if(isDynamicArray!ElementType){
            check_dtor();

            alias ReturnType = RcPtr!(
                ElementType,
                .DestructorType!(
                    .DestructorType!ElementType,
                    DestructorType,
                    DestructorAllocatorType!AllocatorType
                ),
                ControlType
            );

            auto m = ReturnType.MakeDynamicArray!(AllocatorType, supportGC).make(forward!(a, n, args));

            return (m is null)
                ? ReturnType.init
                : ReturnType(m.get, Forward.init);
        }



        /**
            Returns the number of different `RcPtr` instances

            Returns the number of different `RcPtr` instances (`this` included) managing the current object or `0` if there is no managed object.

            Examples:
                --------------------
                RcPtr!long x = null;

                assert(x.useCount == 0);

                x = RcPtr!long.make(123);
                assert(x.useCount == 1);

                auto y = x;
                assert(x.useCount == 2);

                auto w1 = x.weak;    //weak ptr
                assert(x.useCount == 2);

                RcPtr!long.WeakType w2 = x;   //weak ptr
                assert(x.useCount == 2);

                y = null;
                assert(x.useCount == 1);

                x = null;
                assert(x.useCount == 0);
                assert(w1.useCount == 0);
                --------------------
        */
        public @property ControlType.Shared useCount(this This)()const scope nothrow @trusted @nogc{

            static if(is(ControlType.Shared == void))
                return;

            else static if(is(This == shared))
                return this.lockSmartPtr!(
                    (ref scope self) => self.useCount()
                )();

            else
                return (this._element is null)
                    ? 0
                    : this._control.count!false + 1;
            

        }


        /**
            Returns the number of different `RcPtr.WeakType` instances

            Returns the number of different `RcPtr.WeakType` instances (`this` included) managing the current object or `0` if there is no managed object.

            Examples:
                --------------------
                RcPtr!long x = null;
                assert(x.useCount == 0);
                assert(x.weakCount == 0);

                x = RcPtr!long.make(123);
                assert(x.useCount == 1);
                assert(x.weakCount == 0);

                auto w = x.weak();
                assert(x.useCount == 1);
                assert(x.weakCount == 1);
                --------------------
        */
        public @property ControlType.Weak weakCount(this This)()const scope nothrow @safe @nogc{

            static if(is(ControlType.Weak == void))
                return;

            else static if(is(This == shared))
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
                {
                    RcPtr!long a = RcPtr!long.make(1);
                    RcPtr!long b = RcPtr!long.make(2);
                    a.proxySwap(b);
                    assert(*a == 2);
                    assert(*b == 1);
                    import std.algorithm : swap;
                    swap(a, b);
                    assert(*a == 1);
                    assert(*b == 2);
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
            Returns the non `shared` `RcPtr` pointer pointed-to by `shared` `this`.

            Examples:
                --------------------
                shared RcPtr!(long) x = RcPtr!(shared long).make(123);

                {
                    RcPtr!(shared long) y = x.load();
                    assert(y.useCount == 2);

                    assert(y.get == 123);
                }
                --------------------
        */
        public UnqualSmartPtr!This load(MemoryOrder order = MemoryOrder.seq, this This)()scope{

            static if(is(This == shared))
                return this.lockSmartPtr!(
                    (ref scope self) => self.load!order()
                )();
            
            else
                return typeof(return)(this);
            
        }



        /**
            Stores the non `shared` `RcPtr` parameter `ptr` to `this`.

            If `this` is shared then operation is atomic or guarded by mutex.

            Template parameter `order` has type `core.atomic.MemoryOrder`.

            Examples:
                --------------------
                //null store:
                {
                    shared x = RcPtr!(shared long).make(123);
                    assert(x.load.get == 123);

                    x.store(null);
                    assert(x.useCount == 0);
                    assert(x.load == null);
                }

                //rvalue store:
                {
                    shared x = RcPtr!(shared long).make(123);
                    assert(x.load.get == 123);

                    x.store(RcPtr!(shared long).make(42));
                    assert(x.load.get == 42);
                }

                //lvalue store:
                {
                    shared x = RcPtr!(shared long).make(123);
                    auto y = RcPtr!(shared long).make(42);

                    assert(x.load.get == 123);
                    assert(y.load.get == 42);

                    x.store(y);
                    assert(x.load.get == 42);
                    assert(x.useCount == 2);
                }
                --------------------
        */
        public alias store = opAssign;



        /**
            Stores the non `shared` `RcPtr` pointer ptr in the `shared(RcPtr)` pointed to by `this` and returns the value formerly pointed-to by this, atomically or with mutex.

            Examples:
                --------------------
                //lvalue exchange
                {
                    shared x = RcPtr!(shared long).make(123);
                    auto y = RcPtr!(shared long).make(42);

                    auto z = x.exchange(y);

                    assert(x.load.get == 42);
                    assert(y.get == 42);
                    assert(z.get == 123);
                }

                //rvalue exchange
                {
                    shared x = RcPtr!(shared long).make(123);
                    auto y = RcPtr!(shared long).make(42);

                    import core.lifetime : move;
                    auto z = x.exchange(move(y));

                    assert(x.load.get == 42);
                    assert(y == null);
                    assert(z.get == 123);
                }

                //null exchange (same as move)
                {
                    shared x = RcPtr!(shared long).make(123);

                    auto z = x.exchange(null);

                    assert(x.load == null);
                    assert(z.get == 123);
                }

                //swap:
                {
                    shared x = RcPtr!(shared long).make(123);
                    auto y = RcPtr!(shared long).make(42);

                    import core.lifetime : move;
                    //opAssign is same as store
                    y = x.exchange(move(y));

                    assert(x.load.get == 42);
                    assert(y.get == 123);
                }
                --------------------
        */
        public RcPtr exchange(MemoryOrder order = MemoryOrder.seq, this This)(typeof(null))scope
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
        public RcPtr exchange(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(scope Rhs rhs)scope
        if(    isRcPtr!Rhs
            && isMoveAssignable!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static if(is(This == shared)){

                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    return()@trusted{
                        UnqualSmartPtr!This result;
                        GetElementReferenceType!This source = rhs._element;    //interface/class cast

                        result._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            cast(Unqual!(This.ElementReferenceType))source
                        ));
                        rhs._const_reset();

                        return result._move;
                    }();
                }
                else{
                    return this.lockSmartPtr!(
                        (ref scope self, Rhs x) => self.exchange!order(x._move)
                    )(rhs._move);
                }
            }
            else{
                auto result = this._move;

                return()@trusted{
                    this = rhs._move;
                    return result._move;
                }();
            }
        }


        /**
            Compares the `RcPtr` pointers pointed-to by `this` and `expected`.

            If they are equivalent (store the same pointer value, and either share ownership of the same object or are both empty), assigns `desired` into `this` using the memory ordering constraints specified by `success` and returns `true`.
            If they are not equivalent, assigns `this` into `expected` using the memory ordering constraints specified by `failure` and returns `false`.

            More info in c++ std::atomic<std::shared_ptr>.


            Examples:
                --------------------
                static foreach(enum bool weak; [true, false]){
                    //fail
                    {
                        RcPtr!long a = RcPtr!long.make(123);
                        RcPtr!long b = RcPtr!long.make(42);
                        RcPtr!long c = RcPtr!long.make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        assert(*a == 123);
                        assert(*b == 123);
                        assert(*c == 666);

                    }

                    //success
                    {
                        RcPtr!long a = RcPtr!long.make(123);
                        RcPtr!long b = a;
                        RcPtr!long c = RcPtr!long.make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        assert(*a == 666);
                        assert(*b == 123);
                        assert(*c == 666);
                    }

                    //shared fail
                    {
                        shared RcPtr!(shared long) a = RcPtr!(shared long).make(123);
                        RcPtr!(shared long) b = RcPtr!(shared long).make(42);
                        RcPtr!(shared long) c = RcPtr!(shared long).make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        auto tmp = a.exchange(null);
                        assert(*tmp == 123);
                        assert(*b == 123);
                        assert(*c == 666);
                    }

                    //shared success
                    {
                        RcPtr!(shared long) b = RcPtr!(shared long).make(123);
                        shared RcPtr!(shared long) a = b;
                        RcPtr!(shared long) c = RcPtr!(shared long).make(666);

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
        if(    isRcPtr!E && !is(E == shared)
            && isRcPtr!D && !is(D == shared)
            && isMoveAssignable!(D, This)
            && isCopyAssignable!(This, E)
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
        if(    isRcPtr!E && !is(E == shared)
            && isRcPtr!D && !is(D == shared)
            && isMoveAssignable!(D, This)
            && isCopyAssignable!(This, E)
            && (This.isWeak == D.isWeak)
            && (This.isWeak == E.isWeak)
        ){
            return this.compareExchangeImpl!(true, success, failure)(expected, desired._move);
        }


        private bool compareExchangeImpl
            (bool weak, MemoryOrder success, MemoryOrder failure, E, D, this This)
            (ref scope E expected, scope D desired)scope @trusted
        if(    isRcPtr!E && !is(E == shared)
            && isRcPtr!D && !is(D == shared)
            && isMoveAssignable!(D, This)
            && isCopyAssignable!(This, E)
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
            Creates a new non weak `RcPtr` that shares ownership of the managed object (must be `RcPtr.WeakType`).

            If there is no managed object, i.e. this is empty or this is `expired`, then the returned `RcPtr` is empty.
            Method exists only if `RcPtr` is `isWeak`

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);

                    auto w = x.weak;    //weak ptr

                    RcPtr!long y = w.lock;

                    assert(x == y);
                    assert(x.useCount == 2);
                    assert(y.get == 123);
                }

                {
                    RcPtr!long x = RcPtr!long.make(123);

                    auto w = x.weak;    //weak ptr

                    assert(w.expired == false);

                    x = RcPtr!long.make(321);

                    assert(w.expired == true);

                    RcPtr!long y = w.lock;

                    assert(y == null);
                }
                --------------------
        */
        public SharedType lock()()scope
        if(isCopyConstructable!(typeof(this), SharedType)){
            return typeof(return)(this);
        }



        /**
            Equivalent to `useCount() == 0` (must be `RcPtr.WeakType`).

            Method exists only if `RcPtr` is `isWeak`

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);

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
                    RcPtr!long x = RcPtr!long.make(123);
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
                    RcPtr!long x = RcPtr!long.make(123);
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
                public @property inout(ElementType) get()inout return pure nothrow @safe @nogc{
                    return this._element;
                }
            }
            else static if(is(Unqual!ElementType == void)){
                /// ditto
                public @property inout(ElementType) get()inout scope pure nothrow @safe @nogc{
                }
            }
            else{
                /// ditto
                public @property ref ElementType get()return pure nothrow @system @nogc{
                    return *cast(ElementType*)this._element;
                }

                /// ditto
                public @property ref const(inout(ElementType)) get()const inout return pure nothrow @safe @nogc{
                    return *cast(const inout ElementType*)this._element;
                }

            }

        }



        /**
            Get pointer to managed object of `ElementType` or reference if `ElementType` is reference type (class or interface) or dynamic array.

            If `this` is weak expired pointer then return null.

            Doesn't increment useCount, is inherently unsafe.

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);
                    assert(*x.element == 123);

                    x.get = 321;
                    assert(*x.element == 321);

                    const y = x;
                    assert(*y.element == 321);
                    assert(*x.element == 321);

                    static assert(is(typeof(y.element) == const(long)*));
                }

                {
                    auto s = RcPtr!long.make(42);
                    const w = s.weak;

                    assert(*w.element == 42);

                    s = null;
                    assert(w.element is null);
                }

                {
                    auto s = RcPtr!long.make(42);
                    auto w = s.weak;

                    scope const p = w.element;

                    s = null;
                    assert(w.element is null);

                    assert(p !is null); //p is dangling pointer!
                }
                --------------------
        */
        public @property ElementReferenceTypeImpl!(inout ElementType) element()inout return pure nothrow @system @nogc{
            static if(isWeak)
                return (cast(const)this).expired
                    ? null
                    : this._element;
            else
                return this._element;
        }



        /**
            Returns length of dynamic array (isDynamicArray!ElementType == true).

            Examples:
                --------------------
                auto x = RcPtr!(int[]).make(10, -1);
                assert(x.length == 10);
                assert(x.get.length == 10);

                import std.algorithm : all;
                assert(x.get.all!(i => i == -1));
                --------------------
        */
        static if(isDynamicArray!ElementType)
        public @property size_t length()const scope pure nothrow @safe @nogc{
            return this._element.length;
        }


        /**
            Returns weak pointer (must have weak counter).

            Examples:
                --------------------
                RcPtr!long x = RcPtr!long.make(123);
                assert(x.useCount == 1);

                auto wx = x.weak;   //weak pointer
                assert(wx.expired == false);
                assert(wx.lock.get == 123);
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
                RcPtr!long x = RcPtr!long.make(123);
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
            Cast `this` to different type `To` when `isRcPtr!To`.

            BUG: qualfied variable of struct with dtor cannot be inside other struct (generated dtor will use opCast to mutable before dtor call ). opCast is renamed to opCastImpl

            Examples:
                --------------------
                RcPtr!long x = RcPtr!long.make(123);
                auto y = cast(RcPtr!(const long))x;
                auto z = cast(const RcPtr!long)x;
                auto u = cast(const RcPtr!(const long))x;
                assert(x.useCount == 4);
                --------------------
        */
        public To opCastImpl(To, this This)()scope
        if(isRcPtr!To && !is(This == shared)){
            return To(this);
        }


        /**
            Operator == and != .
            Compare pointers.

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(0);
                    assert(x != null);
                    x = null;
                    assert(x == null);
                }

                {
                    RcPtr!long x = RcPtr!long.make(123);
                    RcPtr!long y = RcPtr!long.make(123);
                    assert(x == x);
                    assert(y == y);
                    assert(x != y);
                }

                {
                    RcPtr!long x;
                    RcPtr!(const long) y;
                    assert(x == x);
                    assert(y == y);
                    assert(x == y);
                }

                {
                    RcPtr!long x = RcPtr!long.make(123);
                    RcPtr!long y = RcPtr!long.make(123);
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
        if(isRcPtr!Rhs && !is(Rhs == shared)){
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
                    const a = RcPtr!long.make(42);
                    const b = RcPtr!long.make(123);
                    const n = RcPtr!long.init;

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
                    const a = RcPtr!long.make(42);
                    const b = RcPtr!long.make(123);

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
        if(isRcPtr!Rhs && !is(Rhs == shared)){
            return this.opCmp(rhs._element);
        }



        /**
            Generate hash

            Return:
                Address of payload as `size_t`

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);
                    RcPtr!long y = RcPtr!long.make(123);
                    assert(x.toHash == x.toHash);
                    assert(y.toHash == y.toHash);
                    assert(x.toHash != y.toHash);
                    RcPtr!(const long) z = x;
                    assert(x.toHash == z.toHash);
                }
                {
                    RcPtr!long x;
                    RcPtr!(const long) y;
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

        private void _release()scope{
            if(false){
                DestructorType dt;
                dt(null);
            }

            if(this._element !is null)
                this._control.release!isWeak;
        }

        package GetControlType!This* _control(this This)()pure nothrow @trusted @nogc
        in(this._element !is null){
            static if(isDynamicArray!ElementType){
                return cast(typeof(return))((cast(void*)this._element.ptr) - ControlType.sizeof);
            }
            else static if(is(ElementType == interface)){
                static assert(__traits(getLinkage, ElementType) == "D");
                return cast(typeof(return))((cast(void*)cast(Object)cast(Unqual!ElementType)this._element) - ControlType.sizeof);
            }
            else{
                return cast(typeof(return))((cast(void*)this._element) - ControlType.sizeof);
            }
        }

        private void _reset()scope pure nothrow @system @nogc{
            this._set_element(null);
        }

        package void _const_reset()scope const pure nothrow @system @nogc{
            auto self = cast(Unqual!(typeof(this))*)&this;

            self._reset();
        }

        private void _set_element(ElementReferenceType e)pure nothrow @system @nogc{
            (*cast(Unqual!ElementReferenceType*)&this._element) = cast(Unqual!ElementReferenceType)e;
        }

        private void _const_set_element(ElementReferenceType e)const pure nothrow @system @nogc{
            auto self = cast(Unqual!(typeof(this))*)&this;

            static if(isMutable!ElementReferenceType)
                self._element = e;
            else
                (*cast(Unqual!ElementReferenceType*)&self._element) = cast(Unqual!ElementReferenceType)e;
        }

        package auto _move()@trusted{
            auto e = this._element;
            this._const_reset();

            return typeof(this)(e, Forward.init);
        }

        private alias MakeEmplace(AllocatorType, bool supportGC) = .MakeEmplace!(
            _Type,
            _DestructorType,
            _ControlType,
            AllocatorType,
            supportGC
        );

        private alias MakeDynamicArray(AllocatorType, bool supportGC) = .MakeDynamicArray!(
            _Type,
            _DestructorType,
            _ControlType,
            AllocatorType,
            supportGC
        );

        package alias SmartPtr = .SmartPtr;

        /**/
        package alias ChangeElementType(T) = RcPtr!(
            CopyTypeQualifiers!(ElementType, T),
            DestructorType,
            ControlType,
            isWeak
        );
    }

}



/// Alias to `RcPtr` with different order of template parameters
public template RcPtr(
    _Type,
    _ControlType,
    _DestructorType = DestructorType!_Type
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){
    alias RcPtr = .RcPtr!(_Type, _DestructorType, _ControlType, false);
}

///
unittest{
    static class Foo{
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

    static class Zee : Bar{
        bool b;

        this(int i, double d, bool b)pure nothrow @safe @nogc{
            super(i, d);
            this.b = b;
        }

        ~this()nothrow @system{
        }
    }

    ///simple:
    {
        RcPtr!long a = RcPtr!long.make(42);
        assert(a.useCount == 1);

        RcPtr!(const long) b = a;
        assert(a.useCount == 2);

        RcPtr!long.WeakType w = a.weak; //or WeakRcPtr!long
        assert(a.useCount == 2);
        assert(a.weakCount == 1);

        RcPtr!long c = w.lock;
        assert(a.useCount == 3);
        assert(a.weakCount == 1);

        assert(*c == 42);
        assert(c.get == 42);
    }

    ///polymorphism and aliasing:
    {
        ///create RcPtr
        RcPtr!Foo foo = RcPtr!Bar.make(42, 3.14);
        RcPtr!Zee zee = RcPtr!Zee.make(42, 3.14, false);

        ///dynamic cast:
        RcPtr!Bar bar = dynCast!Bar(foo);
        assert(bar != null);
        assert(foo.useCount == 2);

        ///this doesnt work because Foo destructor attributes are more restrictive then Zee's:
        //RcPtr!Foo x = zee;

        ///this does work:
        RcPtr!(Foo, DestructorType!(Foo, Zee)) x = zee;
        assert(zee.useCount == 2);
    }


    ///multi threading:
    {
        ///create RcPtr with atomic ref counting
        RcPtr!(shared Foo) foo = RcPtr!(shared Bar).make(42, 3.14);

        ///this doesnt work:
        //foo.get.i += 1;

        import core.atomic : atomicFetchAdd;
        atomicFetchAdd(foo.get.i, 1);
        assert(foo.get.i == 43);


        ///creating `shared(RcPtr)`:
        shared RcPtr!(shared Bar) bar = share(dynCast!Bar(foo));

        ///`shared(RcPtr)` is lock free (except `load` and `useCount`/`weakCount`).
        static assert(typeof(bar).isLockFree == true);

        ///multi thread operations (`load`, `store`, `exchange` and `compareExchange`):
        RcPtr!(shared Bar) bar2 = bar.load();
        assert(bar2 != null);
        assert(bar2.useCount == 3);

        RcPtr!(shared Bar) bar3 = bar.exchange(null);
        assert(bar3 != null);
        assert(bar3.useCount == 3);
    }

    ///dynamic array:
    {
        import std.algorithm : all, equal;

        RcPtr!(long[]) a = RcPtr!(long[]).make(10, -1);
        assert(a.length == 10);
        assert(a.get.length == 10);
        assert(a.get.all!(x => x == -1));

        for(int i = 0; i < a.length; ++i){
            a.get[i] = i;
        }
        assert(a.get[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }
}

//old:
pure nothrow @nogc unittest{

    static class Foo{
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
        RcPtr!(const Foo) foo =  RcPtr!Foo.make(42);
        assert(foo.get.i == 42);
        assert(foo.useCount == 1);

        const RcPtr!Foo foo2 = foo;
        assert(foo2.get.i == 42);
        assert(foo.useCount == 2);

    }

    //polymorphic classes:
    {
        RcPtr!Foo foo = RcPtr!Bar.make(42, 3.14);
        assert(foo != null);
        assert(foo.useCount == 1);
        assert(foo.get.i == 42);

        //dynamic cast:
        {
            RcPtr!Bar bar = dynCast!Bar(foo);
            assert(foo.useCount == 2);

            assert(bar.get.i == 42);
            assert(bar.get.d == 3.14);
        }

    }

    //weak references:
    {

        auto x = RcPtr!double.make(3.14);
        assert(x.useCount == 1);
        assert(x.weakCount == 0);

        auto w = x.weak();  //weak pointer
        assert(x.useCount == 1);
        assert(x.weakCount == 1);
        assert(*w.lock == 3.14);

        RcPtr!double.WeakType w2 = x;
        assert(x.useCount == 1);
        assert(x.weakCount == 2);

        assert(w2.expired == false);
        x = null;
        assert(w2.expired == true);
    }

    //dynamic array
    {
        import std.algorithm : all;

        {
            auto arr = RcPtr!(long[]).make(10, -1);

            assert(arr.length == 10);
            assert(arr.get.all!(x => x == -1));
        }

        {
            auto arr = RcPtr!(long[]).make(8);
            assert(arr.length == 8);
            assert(arr.get.all!(x => x == long.init));
        }
    }

    //static array
    {
        import std.algorithm : all;

        {
            auto arr = RcPtr!(long[4]).make(-1);
            assert(arr.get[].all!(x => x == -1));

        }

        {
            long[4] tmp = [0, 1, 2, 3];
            auto arr = RcPtr!(long[4]).make(tmp);
            assert(arr.get[] == tmp[]);
        }
    }

}

///
pure nothrow @safe @nogc unittest{
    //make RcPtr object
    static struct Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    {
        auto foo = RcPtr!Foo.make(42);
        auto foo2 = RcPtr!Foo.make!Mallocator(42);  //explicit stateless allocator
    }

    {
        auto arr = RcPtr!(long[]).make(10); //dynamic array with length 10
        assert(arr.length == 10);
    }
}

///
nothrow unittest{
    //alloc RcPtr object
    import std.experimental.allocator : make, dispose, allocatorObject;

    auto allocator = allocatorObject(Mallocator.instance);

    {
        auto x = RcPtr!(long).alloc(allocator, 42);
    }

    {
        import btl.internal.traits;
        static assert(isMoveConstructableElement!(typeof(allocator)));
        auto arr = RcPtr!(long[]).alloc(allocator, 10); //dynamic array with length 10
        assert(arr.length == 10);
    }

}


//make:
pure nothrow @safe @nogc unittest{
    import std.experimental.allocator : allocatorObject;

    enum bool supportGC = true;

    //
    {
        auto s = RcPtr!long.make(42);
    }

    {
        auto s = RcPtr!long.make!(DefaultAllocator, supportGC)(42);
    }

    {
        auto s = RcPtr!(long, shared(SharedControlBlock)).make!(DefaultAllocator, supportGC)(42);
    }


    // dynamic array:
    {
        auto s = RcPtr!(long[]).make(10, 42);
        assert(s.length == 10);
    }

    {
        auto s = RcPtr!(long[]).make!(DefaultAllocator, supportGC)(10, 42);
        assert(s.length == 10);
    }

    {
        auto s = RcPtr!(long[], shared(SharedControlBlock)).make!(DefaultAllocator, supportGC)(10, 42);
        assert(s.length == 10);
    }
}

//alloc:
nothrow unittest{
    import std.experimental.allocator : allocatorObject;

    auto a = allocatorObject(Mallocator.instance);
    enum bool supportGC = true;

    //
    {
        auto s = RcPtr!long.alloc(a, 42);
    }

    {
        auto s = RcPtr!long.alloc!supportGC(a, 42);
    }

    {
        auto s = RcPtr!(long, shared(SharedControlBlock)).alloc!supportGC(a, 42);
    }


    // dynamic array:
    {
        auto s = RcPtr!(long[]).alloc(a, 10, 42);
        assert(s.length == 10);
    }

    {
        auto s = RcPtr!(long[]).alloc!supportGC(a, 10, 42);
        assert(s.length == 10);
    }

    {
        auto s = RcPtr!(long[], shared(SharedControlBlock)).alloc!supportGC(a, 10, 42);
        assert(s.length == 10);
    }
}



/**
    Dynamic cast for shared pointers if `ElementType` is class with D linkage.

    Creates a new instance of `RcPtr` whose stored pointer is obtained from `ptr`'s stored pointer using a dynaic cast expression.

    If `ptr` is null or dynamic cast fail then result `RcPtr` is null.
    Otherwise, the new `RcPtr` will share ownership with the initial value of `ptr`.
*/
public UnqualSmartPtr!Ptr.ChangeElementType!T dynCast(T, Ptr)(ref scope Ptr ptr)
if(    isRcPtr!Ptr && !is(Ptr == shared) && !Ptr.isWeak
    && isClassOrInterface!T && __traits(getLinkage, T) == "D"
    && isClassOrInterface!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    if(auto element = dynCastElement!T(ptr._element)){
        return typeof(return)(ptr._control, element);
    }

    return typeof(return).init;
}

/// ditto
public UnqualSmartPtr!Ptr.ChangeElementType!T dynCast(T, Ptr)(scope Ptr ptr)
if(    isRcPtr!Ptr && !is(Ptr == shared) && !Ptr.isWeak
    && isClassOrInterface!T && __traits(getLinkage, T) == "D"
    && isClassOrInterface!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    return dynCastMove!T(ptr);
}

/// ditto
public UnqualSmartPtr!Ptr.ChangeElementType!T dynCastMove(T, Ptr)(scope auto ref Ptr ptr)
if(    isRcPtr!Ptr && !is(Ptr == shared) && !Ptr.isWeak
    && isClassOrInterface!T && __traits(getLinkage, T) == "D"
    && isClassOrInterface!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    if(auto element = dynCastElement!T(ptr._element)){
        ()@trusted{
            ptr._const_reset();
        }();
        return typeof(return)(element, Forward.init);
    }

    return typeof(return).init;
}


///
unittest{
    static class Foo{
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

    static class Zee{
    }

    {
        RcPtr!(const Foo) foo = RcPtr!Bar.make(42, 3.14);
        assert(foo.get.i == 42);

        auto bar = dynCast!Bar(foo);
        assert(bar != null);
        assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == RcPtr!(const Bar)));

        auto zee = dynCast!Zee(foo);
        assert(zee == null);
        static assert(is(typeof(zee) == RcPtr!(const Zee)));
    }

    {
        RcPtr!(const Foo) foo = RcPtr!Bar.make(42, 3.14);
        assert(foo.get.i == 42);

        import core.lifetime : move;
        auto bar = dynCast!Bar(foo.move);
        assert(bar != null);
        assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == RcPtr!(const Bar)));
    }

    {
        RcPtr!(const Foo) foo = RcPtr!Bar.make(42, 3.14);
        assert(foo.get.i == 42);

        auto bar = dynCastMove!Bar(foo);
        assert(foo == null);
        assert(bar != null);
        assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == RcPtr!(const Bar)));
    }
}






/**
    Return `shared RcPtr` pointing to same managed object like parameter `ptr`.

    Type of parameter `ptr` must be `RcPtr` with `shared(ControlType)` and `shared`/`immutable` `ElementType` .
*/
public shared(Ptr) share(Ptr)(scope auto ref Ptr ptr)
if(isRcPtr!Ptr){
    import core.lifetime : forward;
    static if(is(Ptr == shared)){
        return forward!ptr;
    }
    else{
        static assert(is(GetControlType!Ptr == shared) || is(GetControlType!Ptr == immutable),
            "`RcPtr` has not shared ref counter `ControlType`."
        );

        static assert(is(GetElementType!Ptr == shared) || is(GetElementType!Ptr == immutable),
            "`RcPtr` has not shared/immutable `ElementType`."
        );

        return typeof(return)(forward!ptr, Forward.init);
    }
}

///
nothrow @nogc unittest{
    {
        auto x = RcPtr!(shared long).make(123);
        assert(x.useCount == 1);

        shared s1 = share(x);
        assert(x.useCount == 2);


        import core.lifetime : move;
        shared s2 = share(x.move);
        assert(x == null);
        assert(s2.useCount == 2);
        assert(s2.load.get == 123);

    }

    {
        auto x = RcPtr!(long).make(123);
        assert(x.useCount == 1);

        ///error `shared RcPtr` need shared `ControlType` and shared `ElementType`.
        //shared s1 = share(x);

    }

}



/**
    Return `RcPtr` pointing to first element of dynamic array managed by rc pointer `ptr`.
*/
public auto first(Ptr)(scope ref Ptr ptr)@trusted
if(isRcPtr!Ptr && is(Ptr.ElementType : T[], T)){
    import std.traits : isDynamicArray, isStaticArray;
    import std.range : ElementEncodingType;

    alias Result = UnqualSmartPtr!Ptr.ChangeElementType!(
        ElementEncodingType!(Ptr.ElementType)
    );

    if(ptr == null)
        return Result.init;

    static if(isDynamicArray!(Ptr.ElementType) || isStaticArray!(Ptr.ElementType)){
        return Result(ptr._control, ptr._element.ptr);
    }
    else static assert(0, "no impl");
}

/// ditto
public auto first(Ptr)(scope Ptr ptr)@trusted
if(isRcPtr!Ptr && is(Ptr.ElementType : T[], T)){
    import std.traits : isDynamicArray, isStaticArray;
    import std.range : ElementEncodingType;

    alias Result = UnqualSmartPtr!Ptr.ChangeElementType!(
        ElementEncodingType!(Ptr.ElementType)
    );

    if(ptr == null)
        return Result.init;

    static if(isDynamicArray!(Ptr.ElementType) || isStaticArray!(Ptr.ElementType)){
        auto ptr_element = ptr._element.ptr;
        ptr._const_reset();
        return Result(ptr_element, Forward.init);
    }
    else static assert(0, "no impl");
}

///
pure nothrow @nogc unittest{
    //copy
    {
        auto x = RcPtr!(long[]).make(10, -1);
        assert(x.length == 10);

        auto y = first(x);
        static assert(is(typeof(y) == RcPtr!long));
        assert(*y == -1);
        assert(x.useCount == 2);
    }

    {
        auto x = RcPtr!(long[10]).make(-1);
        assert(x.get.length == 10);

        auto y = first(x);
        static assert(is(typeof(y) == RcPtr!long));
        assert(*y == -1);
        assert(x.useCount == 2);
    }

    //move
    import core.lifetime : move;
    {
        auto x = RcPtr!(long[]).make(10, -1);
        assert(x.length == 10);

        auto y = first(x.move);
        static assert(is(typeof(y) == RcPtr!long));
        assert(*y == -1);
    }

    {
        auto x = RcPtr!(long[10]).make(-1);
        assert(x.get.length == 10);

        auto y = first(x.move);
        static assert(is(typeof(y) == RcPtr!long));
        assert(*y == -1);
    }
}



//local traits:
private{

    //Constructable:
    template isMoveConstructable(From, To){
        import std.traits : Unqual, CopyTypeQualifiers;

        static if(is(Unqual!(From.ElementType) == Unqual!(To.ElementType)))
            enum bool overlapable = true;

        else static if(isClassOrInterface!(From.ElementType) && isClassOrInterface!(To.ElementType))
            enum bool overlapable = true
                && (__traits(getLinkage, From.ElementType) == "D")
                && (__traits(getLinkage, To.ElementType) == "D");
        else
            enum bool overlapable = false;


        enum bool isMoveConstructable = true
            && overlapable    //isOverlapable!(From.ElementType, To.ElementType) //&& is(Unqual!(From.ElementType) == Unqual!(To.ElementType))
            && is(GetElementReferenceType!From : GetElementReferenceType!To)
            && is(From.DestructorType : To.DestructorType)
            && is(GetControlType!From* : GetControlType!To*);
    }
    template isCopyConstructable(From, To){
        import std.traits : isMutable;

        enum bool isCopyConstructable = true
            && isMoveConstructable!(From, To)
            && isMutable!From
            && isMutable!(From.ControlType);
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


        static struct Test{}

        import std.meta : AliasSeq;
        //alias Test = long;
        static foreach(alias ControlType; AliasSeq!(SharedControlBlock, shared SharedControlBlock)){{
            alias SPtr(T) = RcPtr!(T, DestructorType!T, ControlType);

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
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(!__traits(compiles, shared(Ptr)(ptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(ptr)));
            }

            //immutable:
            {
                alias Ptr = SPtr!(immutable Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(__traits(compiles, shared(Ptr)(ptr)) == is(ControlType == shared));
                static assert(__traits(compiles, const(shared(Ptr))(ptr)) == is(ControlType == shared));
            }


            //shared:
            {
                alias Ptr = SPtr!(shared Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(__traits(compiles, shared(Ptr)(ptr)) == is(ControlType == shared));
                static assert(__traits(compiles, const(shared(Ptr))(ptr)) == is(ControlType == shared));
            }


            //const shared:
            {
                alias Ptr = SPtr!(const shared Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(__traits(compiles, shared(Ptr)(ptr)) == is(ControlType == shared));
                static assert(__traits(compiles, const(shared(Ptr))(ptr)) == is(ControlType == shared));
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
        RcPtr!long x = null;

        assert(x == null);
        assert(x == RcPtr!long.init);

    }


    //opAssign(RcPtr)
    pure nothrow @nogc unittest{

        {
            RcPtr!long px1 = RcPtr!long.make(1);
            RcPtr!long px2 = RcPtr!long.make(2);

            assert(px2.useCount == 1);
            px1 = px2;
            assert(px1.get == 2);
            assert(px2.useCount == 2);
        }



        {
            RcPtr!long px = RcPtr!long.make(1);
            RcPtr!(const long) pcx = RcPtr!long.make(2);

            assert(px.useCount == 1);
            pcx = px;
            assert(pcx.get == 1);
            assert(pcx.useCount == 2);

        }


        /+{
            const RcPtr!long cpx = RcPtr!long.make(1);
            RcPtr!(const long) pcx = RcPtr!long.make(2);

            assert(pcx.useCount == 1);
            pcx = cpx;
            assert(pcx.get == 1);
            assert(pcx.useCount == 2);

        }+/

        {
            RcPtr!(immutable long) pix = RcPtr!(immutable long).make(123);
            RcPtr!(const long) pcx = RcPtr!long.make(2);

            assert(pix.useCount == 1);
            pcx = pix;
            assert(pcx.get == 123);
            assert(pcx.useCount == 2);

        }
    }

    //opAssign(null)
    nothrow @safe @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x == null);
        }

        {
            RcPtr!(shared long) x = RcPtr!(shared long).make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x == null);
        }

        import btl.internal.mutex : supportMutex;
        static if(supportMutex){
            shared RcPtr!(long) x = RcPtr!(shared long).make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x.load == null);
        }
    }

    //useCount
    pure nothrow @safe @nogc unittest{
        RcPtr!long x = null;

        assert(x.useCount == 0);

        x = RcPtr!long.make(123);
        assert(x.useCount == 1);

        auto y = x;
        assert(x.useCount == 2);

        auto w1 = x.weak;    //weak ptr
        assert(x.useCount == 2);

        RcPtr!long.WeakType w2 = x;   //weak ptr
        assert(x.useCount == 2);

        y = null;
        assert(x.useCount == 1);

        x = null;
        assert(x.useCount == 0);
        assert(w1.useCount == 0);
    }

    //weakCount
    pure nothrow @safe @nogc unittest{

        RcPtr!long x = null;
        assert(x.useCount == 0);
        assert(x.weakCount == 0);

        x = RcPtr!long.make(123);
        assert(x.useCount == 1);
        assert(x.weakCount == 0);

        auto w = x.weak();
        assert(x.useCount == 1);
        assert(x.weakCount == 1);
    }

    // store:
    nothrow @nogc unittest{

        //null store:
        {
            shared x = RcPtr!(shared long).make(123);
            assert(x.load.get == 123);

            x.store(null);
            assert(x.useCount == 0);
            assert(x.load == null);
        }

        //rvalue store:
        {
            shared x = RcPtr!(shared long).make(123);
            assert(x.load.get == 123);

            x.store(RcPtr!(shared long).make(42));
            assert(x.load.get == 42);
        }

        //lvalue store:
        {
            shared x = RcPtr!(shared long).make(123);
            auto y = RcPtr!(shared long).make(42);

            assert(x.load.get == 123);
            assert(y.load.get == 42);
            assert(x.useCount == 1);

            x.store(y);
            assert(x.load.get == 42);
            assert(x.useCount == 2);
        }
    }

    //load:
    nothrow @nogc unittest{

        shared RcPtr!(long) x = RcPtr!(shared long).make(123);

        import btl.internal.mutex : supportMutex;
        static if(supportMutex){
            RcPtr!(shared long) y = x.load();
            assert(y.useCount == 2);

            assert(y.get == 123);
        }

    }

    //exchange
    nothrow @nogc unittest{

        //lvalue exchange
        {
            shared x = RcPtr!(shared long).make(123);
            auto y = RcPtr!(shared long).make(42);

            auto z = x.exchange(y);

            assert(x.load.get == 42);
            assert(y.get == 42);
            assert(z.get == 123);
        }

        //rvalue exchange
        {
            shared x = RcPtr!(shared long).make(123);
            auto y = RcPtr!(shared long).make(42);

            import core.lifetime : move;
            auto z = x.exchange(y.move);

            assert(x.load.get == 42);
            assert(y == null);
            assert(z.get == 123);
        }

        //null exchange (same as move)
        {
            shared x = RcPtr!(shared long).make(123);

            auto z = x.exchange(null);

            assert(x.load == null);
            assert(z.get == 123);
        }

        //swap:
        {
            shared x = RcPtr!(shared long).make(123);
            auto y = RcPtr!(shared long).make(42);

            //opAssign is same as store
            import core.lifetime : move;
            y = x.exchange(y.move);

            assert(x.load.get == 42);
            assert(y.get == 123);
        }

    }


    //compareExchange
    pure nothrow @nogc unittest{
        static class Foo{
            long i;
            this(long i)pure nothrow @safe @nogc{
                this.i = i;
            }

            bool opEquals(this This)(long i)const @trusted{
                import std.traits : Unqual;
                auto self = cast(Unqual!This)this;
                return (self.i == i);
            }


        }
        alias Type = const Foo;
        static foreach(enum bool weak; [true, false]){
            //fail
            {
                RcPtr!Type a = RcPtr!Type.make(123);
                RcPtr!Type b = RcPtr!Type.make(42);
                RcPtr!Type c = RcPtr!Type.make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                assert(*a == 123);
                assert(*b == 123);
                assert(*c == 666);

            }

            //success
            {
                RcPtr!Type a = RcPtr!Type.make(123);
                RcPtr!Type b = a;
                RcPtr!Type c = RcPtr!Type.make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                assert(*a == 666);
                assert(*b == 123);
                assert(*c == 666);
            }

            //shared fail
            {
                shared RcPtr!(shared Type) a = RcPtr!(shared Type).make(123);
                RcPtr!(shared Type) b = RcPtr!(shared Type).make(42);
                RcPtr!(shared Type) c = RcPtr!(shared Type).make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                auto tmp = a.exchange(null);
                assert(*tmp == 123);
                assert(*b == 123);
                assert(*c == 666);
            }

            //shared success
            {
                RcPtr!(shared Type) b = RcPtr!(shared Type).make(123);
                shared RcPtr!(shared Type) a = b;
                RcPtr!(shared Type) c = RcPtr!(shared Type).make(666);

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
        {
            RcPtr!long x = RcPtr!long.make(123);

            auto w = x.weak;    //weak ptr

            RcPtr!long y = w.lock;

            assert(x == y);
            assert(x.useCount == 2);
            assert(y.get == 123);
        }

        {
            RcPtr!long x = RcPtr!long.make(123);

            auto w = x.weak;    //weak ptr

            assert(w.expired == false);

            x = RcPtr!long.make(321);

            assert(w.expired == true);

            RcPtr!long y = w.lock;

            assert(y == null);
        }
        {
            shared RcPtr!(shared long) x = RcPtr!(shared long).make(123);

            shared RcPtr!(shared long).WeakType w = x.load.weak;    //weak ptr

            assert(w.expired == false);

            x = RcPtr!(shared long).make(321);

            assert(w.expired == true);

            RcPtr!(shared long) y = w.load.lock;

            assert(y == null);
        }
    }

    //expired
    nothrow @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(123);

            auto wx = x.weak;   //weak pointer

            assert(wx.expired == false);

            x = null;

            assert(wx.expired == true);
        }
    }

    //make
    pure nothrow @nogc unittest{
        {
            RcPtr!long a = RcPtr!long.make();
            assert(a.get == 0);

            RcPtr!(const long) b = RcPtr!long.make(2);
            assert(b.get == 2);
        }

        {
            static struct Struct{
                int i = 7;

                this(int i)pure nothrow @safe @nogc{
                    this.i = i;
                }
            }

            RcPtr!Struct s1 = RcPtr!Struct.make();
            assert(s1.get.i == 7);

            RcPtr!Struct s2 = RcPtr!Struct.make(123);
            assert(s2.get.i == 123);
        }

        static interface Interface{
        }
        static class Class : Interface{
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {

            RcPtr!Interface x = RcPtr!Class.make(3);
            //assert(x.dynTo!Class.get.i == 3);
        }


    }

    //make dynamic array
    pure nothrow @nogc unittest{
        {
            auto arr = RcPtr!(long[]).make(6, -1);
            assert(arr.length == 6);
            assert(arr.get.length == 6);

            import std.algorithm : all;
            assert(arr.get.all!(x => x == -1));

            for(int i = 0; i < 6; ++i)
                arr.get[i] = i;

            assert(arr.get == [0, 1, 2, 3, 4, 5]);
        }

        {
            static struct Struct{
                int i;
                double d;
            }

            {
                auto a = RcPtr!(Struct[]).make(6, 42, 3.14);
                assert(a.length == 6);
                assert(a.get.length == 6);

                import std.algorithm : all;
                assert(a.get[].all!(x => (x.i == 42 && x.d == 3.14)));
            }

            {
                auto a = RcPtr!(Struct[]).make(6);
                assert(a.length == 6);

                import std.algorithm : all;
                assert(a.get[].all!(x => (x.i == int.init)));
            }
        }

        {
            static class Class{
                int i;
                double d;

                this(int i, double d){
                    this.i = i;
                    this.d = d;
                }
            }

            {
                auto a = RcPtr!(Class[]).make(6, null);
                assert(a.length == 6);

                import std.algorithm : all;
                assert(a.get[].all!(x => x is null));
            }

            {
                auto a = RcPtr!(Class[]).make(6);
                assert(a.length == 6);

                import std.algorithm : all;
                assert(a.get[].all!(x => x is null));
            }


        }
    }

    //make static array
    pure nothrow @nogc unittest{
        import std.algorithm : all;
        {
            RcPtr!(long[6]) a = RcPtr!(long[6]).make();
            assert(a.get.length == 6);
            assert(a.get[].all!(x => x == long.init));
        }
        {
            RcPtr!(long[6]) a = RcPtr!(long[6]).make(-1);
            assert(a.get.length == 6);
            assert(a.get[].all!(x => x == -1));
        }
        {
            long[6] tmp = [1, 2, 3, 4, 5, 6];

            RcPtr!(const(long)[6]) a = RcPtr!(long[6]).make(tmp);
            assert(a.get.length == 6);
            assert(a.get[]== tmp);
        }
        {
            static struct Struct{
                int i;
                double d;
            }

            auto a = RcPtr!(Struct[6]).make(42, 3.14);
            assert(a.get.length == 6);

            import std.algorithm : all;
            assert(a.get[].all!(x => (x.i == 42 && x.d == 3.14)));


        }
    }

    //alloc
    pure nothrow @nogc unittest{
        {
            TestAllocator allocator;

            {
                RcPtr!long a = RcPtr!long.alloc(&allocator);
                assert(a.get == 0);

                RcPtr!(const long) b = RcPtr!long.alloc(&allocator, 2);
                assert(b.get == 2);
            }

            {
                static struct Struct{
                    int i = 7;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                RcPtr!Struct s1 = RcPtr!Struct.alloc(allocator);
                assert(s1.get.i == 7);

                RcPtr!Struct s2 = RcPtr!Struct.alloc(allocator, 123);
                assert(s2.get.i == 123);
            }

            static interface Interface{
            }
            static class Class : Interface{
                int i;

                this(int i)pure nothrow @safe @nogc{
                    this.i = i;
                }
            }

            {


                RcPtr!Interface x = RcPtr!Class.alloc(&allocator, 3);
                assert(x.useCount == 1);
                //assert(x.dynTo!Class.get.i == 3);
            }
        }
    }

    //alloc
    unittest{

        {
            import std.experimental.allocator : allocatorObject;

            auto a = allocatorObject(Mallocator.instance);
            {
                auto x = RcPtr!long.alloc(a);
                assert(x.get == 0);

                auto y = RcPtr!long.alloc(a, 2);
                assert(y.get == 2);
            }

            {
                static struct Struct{
                    int i = 7;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                auto s1 = RcPtr!Struct.alloc(a);
                assert(s1.get.i == 7);

                auto s2 = RcPtr!Struct.alloc(a, 123);
                assert(s2.get.i == 123);
            }

            {
                static interface Interface{
                }
                static class Class : Interface{
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                RcPtr!(Interface, DestructorAllocatorType!(typeof(a))) x = RcPtr!Class.alloc(a, 3);
                //assert(x.dynTo!Class.get.i == 3);
            }

        }
    }

    //alloc array
    nothrow unittest{
        {
            import std.experimental.allocator : allocatorObject;

            auto a = allocatorObject(Mallocator.instance);
            auto arr = RcPtr!(long[], DestructorAllocatorType!(typeof(a))).alloc(a, 6, -1);
            assert(arr.length == 6);
            assert(arr.get.length == 6);

            import std.algorithm : all;
            assert(arr.get.all!(x => x == -1));

            for(int i = 0; i < 6; ++i)
                arr.get[i] = i;

            assert(arr.get == [0, 1, 2, 3, 4, 5]);
        }
    }

    //ctor
    pure nothrow @nogc @safe unittest{

        {
            RcPtr!long x = RcPtr!long.make(123);
            assert(x.useCount == 1);

            RcPtr!long a = x;         //lvalue copy ctor
            assert(a == x);

            const RcPtr!long b = x;   //lvalue copy ctor
            assert(b == x);

            RcPtr!(const long) c = x; //lvalue ctor
            assert(c == x);

            const RcPtr!long d = a;   //lvalue ctor
            assert(d == x);

            assert(x.useCount == 5);
        }

        {
            import core.lifetime : move;
            RcPtr!long x = RcPtr!long.make(123);
            assert(x.useCount == 1);

            RcPtr!long a = move(x);        //rvalue copy ctor
            assert(a.useCount == 1);

            const RcPtr!long b = move(a);  //rvalue copy ctor
            assert(b.useCount == 1);

            /+RcPtr!(const long) c = b.load;  //rvalue ctor
            assert(c.useCount == 2);

            const RcPtr!long d = move(c);  //rvalue ctor
            assert(d.useCount == 2);+/
        }

        /+{
            import core.lifetime : move;
            auto u = UniquePtr!(long, SharedControlBlock).make(123);

            RcPtr!long s = move(u);        //rvalue copy ctor
            assert(s != null);
            assert(s.useCount == 1);

            RcPtr!long s2 = UniquePtr!(long, SharedControlBlock).init;
            assert(s2 == null);

        }+/

    }

    //weak
    pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        assert(x.useCount == 1);
        auto wx = x.weak;   //weak pointer
        assert(wx.expired == false);
        assert(wx.lock.get == 123);
        assert(wx.useCount == 1);
        x = null;
        assert(wx.expired == true);
        assert(wx.useCount == 0);

    }

    //operator *
    pure nothrow @nogc unittest{

        RcPtr!long x = RcPtr!long.make(123);
        assert(*x == 123);
        (*x = 321);
        assert(*x == 321);
        const y = x;
        assert(*y == 321);
        assert(*x == 321);
        static assert(is(typeof(*y) == const long));
    }

    //get
    pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        assert(x.get == 123);
        x.get = 321;
        assert(x.get == 321);
        const y = x;
        assert(y.get == 321);
        assert(x.get == 321);
        static assert(is(typeof(y.get) == const long));
    }

    //element
    pure nothrow @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(123);
            assert(*x.element == 123);

            x.get = 321;
            assert(*x.element == 321);

            const y = x;
            assert(*y.element == 321);
            assert(*x.element == 321);

            static assert(is(typeof(y.element) == const(long)*));
        }

        {
            auto s = RcPtr!long.make(42);
            const w = s.weak;

            assert(*w.element == 42);

            s = null;
            assert(w.element is null);
        }

        {
            auto s = RcPtr!long.make(42);
            auto w = s.weak;

            scope const p = w.element;

            s = null;
            assert(w.element is null);

            assert(p !is null); //p is dangling pointer!
        }
    }

    //opCast bool
    @safe pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        assert(cast(bool)x);    //explicit cast
        assert(x);              //implicit cast
        x = null;
        assert(!cast(bool)x);   //explicit cast
        assert(!x);             //implicit cast
    }

    //opCast RcPtr
    /+TODO
    @safe pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        auto y = cast(RcPtr!(const long))x;
        auto z = cast(const RcPtr!long)x;
        auto u = cast(const RcPtr!(const long))x;
        assert(x.useCount == 4);
    }
    +/

    //opEquals RcPtr
    pure @safe nothrow @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(0);
            assert(x != null);
            x = null;
            assert(x == null);
        }

        {
            RcPtr!long x = RcPtr!long.make(123);
            RcPtr!long y = RcPtr!long.make(123);
            assert(x == x);
            assert(y == y);
            assert(x != y);
        }

        {
            RcPtr!long x;
            RcPtr!(const long) y;
            assert(x == x);
            assert(y == y);
            assert(x == y);
        }
    }

    //opEquals RcPtr
    pure nothrow @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(123);
            RcPtr!long y = RcPtr!long.make(123);
            assert(x == x.element);
            assert(y.element == y);
            assert(x != y.element);
        }
    }

    //opCmp
    pure nothrow @safe @nogc unittest{
        {
            const a = RcPtr!long.make(42);
            const b = RcPtr!long.make(123);
            const n = RcPtr!long.init;

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
        {
            const a = RcPtr!long.make(42);
            const b = RcPtr!long.make(123);

            assert(a <= a.element);
            assert(a.element >= a);

            assert((a < b.element) == !(a.element >= b));
            assert((a > b.element) == !(a.element <= b));
        }
    }

    //toHash
    pure nothrow @safe @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(123);
            RcPtr!long y = RcPtr!long.make(123);
            assert(x.toHash == x.toHash);
            assert(y.toHash == y.toHash);
            assert(x.toHash != y.toHash);
            RcPtr!(const long) z = x;
            assert(x.toHash == z.toHash);
        }
        {
            RcPtr!long x;
            RcPtr!(const long) y;
            assert(x.toHash == x.toHash);
            assert(y.toHash == y.toHash);
            assert(x.toHash == y.toHash);
        }
    }

    //proxySwap
    pure nothrow @nogc unittest{
        {
            RcPtr!long a = RcPtr!long.make(1);
            RcPtr!long b = RcPtr!long.make(2);
            a.proxySwap(b);
            assert(*a == 2);
            assert(*b == 1);
            import std.algorithm : swap;
            swap(a, b);
            assert(*a == 1);
            assert(*b == 2);
            assert(a.useCount == 1);
            assert(b.useCount == 1);
        }
    }

    //length
    pure nothrow @nogc unittest{
        auto x = RcPtr!(int[]).make(10, -1);
        assert(x.length == 10);
        assert(x.get.length == 10);

        import std.algorithm : all;
        assert(x.get.all!(i => i == -1));
    }

}

pure nothrow @safe @nogc unittest{
    RcPtr!void u = RcPtr!void.make();
}


version(unittest){
    struct Foo{
        RcPtr!int i;
    }
}



//test strong ptr -> weak ptr move ctor
unittest{
    {
        import core.lifetime : move;

        auto a = RcPtr!int.make(1);
        auto b = a;
        assert(a.useCount == 2);
        assert(a.weakCount == 0);

        RcPtr!int.WeakType x = move(a);
        assert(b.useCount == 1);
        assert(b.weakCount == 1);
    }
}

//test strong ptr -> weak ptr assign
unittest{
    {
        import core.lifetime : move;

        auto a = RcPtr!int.make(1);
        auto b = RcPtr!int.make(2);

        {
            RcPtr!int.WeakType x = RcPtr!int(a);
            assert(a.useCount == 1);
            assert(a.weakCount == 1);

            x = RcPtr!int(b);
            assert(a.useCount == 1);
            assert(a.weakCount == 0);

            assert(b.useCount == 1);
            assert(b.weakCount == 1);
        }
        {
            RcPtr!int.WeakType x = a;
            assert(a.useCount == 1);
            assert(a.weakCount == 1);

            RcPtr!int.WeakType y = b;
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
    auto a = RcPtr!int.make(1);
    auto b = a.weak;
    assert(a == b);
}

//self opAssign
unittest{
    auto a = RcPtr!long.make(1);
    a = a;
}

version(unittest){
//debug{
    private struct Cycle{

        RcPtr!(Cycle, DestructorType!void, SharedControlBlock) cycle;

        ~this()pure nothrow @safe @nogc{}
    }
}
