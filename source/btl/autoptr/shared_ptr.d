/**
	Implementation of reference counted pointer `SharedPtr` (similar to c++ `std::shared_ptr`).

	License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
	Authors:   $(HTTP github.com/submada/basic_string, Adam Búš)
*/
module btl.autoptr.shared_ptr;

import btl.internal.mallocator;
import btl.internal.traits;
import btl.internal.gc;

import btl.autoptr.common;
//import btl.autoptr.rc_ptr : RcPtr, isRcPtr;
//import btl.autoptr.intrusive_ptr : IntrusivePtr, isIntrusivePtr;



/**
	Check if type `T` is `SharedPtr`.
*/
public template isSharedPtr(T){
	import std.traits : isInstanceOf;

	enum bool isSharedPtr = isInstanceOf!(SharedPtr, T);
}

///
unittest{
	static assert(!isSharedPtr!long);
	static assert(!isSharedPtr!(void*));

	static assert(isSharedPtr!(SharedPtr!long));
	static assert(isSharedPtr!(SharedPtr!long.WeakType));
}



/**
	Implementation of a ref counted pointer with support for aliasing.
    
	`SharedPtr` retains shared ownership of an object through a pointer.

	Several `SharedPtr` objects may own the same object.

	The object is destroyed and its memory deallocated when either of the following happens:

		1. the last remaining `SharedPtr` owning the object is destroyed.

		2. the last remaining `SharedPtr` owning the object is assigned another pointer via various methods like `opAssign` and `store`.

	The object is destroyed using delete-expression or a custom deleter that is supplied to `SharedPtr` during construction.

	A `SharedPtr` can share ownership of an object while storing a pointer to another object.
	This feature can be used to point to member objects while owning the object they belong to.
	The stored pointer is the one accessed by `get()`, the dereference and the comparison operators.
	The managed pointer is the one passed to the deleter when use count reaches zero.

	A `SharedPtr` may also own no objects, in which case it is called empty (an empty `SharedPtr` may have a non-null stored pointer if the aliasing constructor was used to create it).

	If template parameter `_ControlType` is `shared`  then all member functions (including copy constructor and copy assignment)
	can be called by multiple threads on different instances of `SharedPtr` without additional synchronization even if these instances are copies and share ownership of the same object.

	If multiple threads of execution access the same `SharedPtr` (`shared SharedPtr`) then only some methods can be called (`load`, `store`, `exchange`, `compareExchange`, `useCount`).

	Template parameters:

		`_Type` type of managed object

		`_DestructorType` function pointer with attributes of destructor, to get attributes of destructor from type use `btl.autoptr.common.DestructorType!T`. Destructor of type `_Type` must be compatible with `_DestructorType`

		`_ControlType` represent type of counter, must by of type `btl.autoptr.common.ControlBlock`. if is shared then ref counting is atomic.

		`_weakPtr` if `true` then `SharedPtr` represent weak ptr

*/
public template SharedPtr(
	_Type,
	_DestructorType = DestructorType!_Type,
	_ControlType = ControlBlockDeduction!(_Type, SharedControlBlock),
	bool _weakPtr = false
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){

	static assert(_ControlType.hasSharedCounter || is(_ControlType == immutable),
		"_ControlType must be `ControlBlock` with shared counter or `ControlBlock` must be immutable."
	);

	static assert(!_weakPtr || _ControlType.hasWeakCounter,
		"weak pointer must have control block with weak counter"
	);

	static if (is(_Type == class) || is(_Type == interface) || is(_Type == struct) || is(_Type == union))
		static assert(!__traits(isNested, _Type),
			"SharedPtr does not support nested types."
		);

	static assert(is(DestructorType!void : _DestructorType),
		_Type.stringof ~ " wrong DestructorType " ~ DestructorType!void.stringof ~
		" : " ~ _DestructorType.stringof
	);

	static assert(is(DestructorType!_Type : _DestructorType),
		"destructor of type '" ~ _Type.stringof ~
		"' doesn't support specified finalizer " ~ _DestructorType.stringof
	);

	import std.meta : AliasSeq;
	import std.range : ElementEncodingType;
	import std.traits: Unqual, Unconst, CopyTypeQualifiers, CopyConstness,
		hasIndirections, hasElaborateDestructor,
		isMutable, isAbstractClass, isDynamicArray, isStaticArray, isCallable, Select, isArray;

	import core.atomic : MemoryOrder;
	import core.lifetime : forward;

	enum bool hasWeakCounter = _ControlType.hasWeakCounter;

	enum bool hasSharedCounter = _ControlType.hasSharedCounter;

	enum bool referenceElementType = isReferenceType!_Type || isDynamicArray!_Type;

	static if(isDynamicArray!_Type)
		alias ElementDestructorType = .DestructorType!void;
	else
		alias ElementDestructorType = .DestructorType!_Type;


	enum bool _isLockFree = false;

	struct SharedPtr{

		/**
			Type of element managed by `SharedPtr`.
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
			`true` if `SharedPtr` is weak ptr.
		*/
		public alias isWeak = _weakPtr;


		/**
			Same as `ElementType*` or `ElementType` if is class/interface/slice.
		*/
		public alias ElementReferenceType = ElementReferenceTypeImpl!ElementType;


		/**
			Weak pointer

			`SharedPtr.WeakType` is a smart pointer that holds a non-owning ("weak") reference to an object that is managed by `SharedPtr`.
			It must be converted to `SharedPtr` in order to access the referenced object.

			`SharedPtr.WeakType` models temporary ownership: when an object needs to be accessed only if it exists, and it may be deleted at any time by someone else,
			`SharedPtr.WeakType` is used to track the object, and it is converted to `SharedPtr` to assume temporary ownership.
			If the original `SharedPtr` is destroyed at this time, the object's lifetime is extended until the temporary `SharedPtr` is destroyed as well.

			Another use for `SharedPtr.WeakType` is to break reference cycles formed by objects managed by `SharedPtr`.
			If such cycle is orphaned (i,e. there are no outside shared pointers into the cycle), the `SharedPtr` reference counts cannot reach zero and the memory is leaked.
			To prevent this, one of the pointers in the cycle can be made weak.
		*/
		static if(hasWeakCounter)
			public alias WeakType = SharedPtr!(
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
		public alias SharedType = SharedPtr!(
			_Type,
			_DestructorType,
			_ControlType,
			false
		);



		/**
			`true` if shared `SharedPtr` has lock free operations `store`, `load`, `exchange`, `compareExchange`, otherwise 'false'
		*/
		public alias isLockFree = _isLockFree;

		static if(isLockFree)
			static assert(ElementReferenceType.sizeof == size_t.sizeof);



		/**
			Destructor

			If `this` owns an object and it is the last `SharedPtr` owning it, the object is destroyed.
			After the destruction, the smart pointers that shared ownership with `this`, if any, will report a `useCount()` that is one less than its previous value.
		*/
		public ~this(){
			this._release();
		}



		// necessary for btl.autoptr.unique_ptr.sharedPtr
		package this(C, Elm, this This)(C* control, Elm element)@safe pure nothrow @nogc
		if(true
			&& is(C* : GetControlType!This*)
			&& is(Elm : GetElementReferenceType!This)
			&& !is(This == shared)
		){
			this._control = control;
			this._element = element;
		}


		/**
			Forward constructor (merge move and copy constructor).
		*/
		public this(Rhs, this This)(auto ref scope Rhs rhs, Forward)@trusted //if rhs is rvalue then dtor is called on empty rhs
		if(    isSmartPtr!Rhs	//(isSharedPtr!Rhs || isRcPtr!Rhs || isIntrusivePtr!Rhs)
			&& isConstructable!(rhs, This)
			&& !is(Rhs == shared)
		){
			//lock (copy):
			static if(weakLock!(Rhs, This)){
				if(rhs._control !is null && rhs._control.add_shared_if_exists()){
					this._control = rhs._control;
					this._element = rhs._element;
				}
				/+else{
					this._control = null;
					this._element = null;
				}+/
			}
			else if(rhs._element !is null){
				this._control = rhs._control;
				this._element = rhs._element;

				//copy or lock(copy):
				static if(isRef!rhs || (isWeak && !Rhs.isWeak)){
					if(this._control !is null)
						rhs._control.add!isWeak;
				}
				//move:
				else{
					rhs._const_reset();
				}

			}
		}


		/**
			Constructs a `SharedPtr` without managed object. Same as `SharedPtr.init`

			Examples:
				--------------------
				SharedPtr!long x = null;

				assert(x == null);
				assert(x == SharedPtr!long.init);
				--------------------
		*/
		public this(this This)(typeof(null) nil)pure nothrow @safe @nogc{
		}



		/**
			Constructs a `SharedPtr` which shares ownership of the object managed by `rhs` and pointing to `element`.

			The aliasing constructor: constructs a `SharedPtr` which shares ownership information with the initial value of `rhs`,
				but holds an unrelated and unmanaged pointer ptr. If this `SharedPtr` is the last of the group to go out of scope,
				it will call the stored deleter for the object originally managed by `rhs`.
				However, calling `get()` or `ptr()` on this `SharedPtr` will always return a copy of `element`.
				It is the responsibility of the programmer to make sure that this ptr remains valid as long as this `SharedPtr` exists,
				such as in the typical use cases where `element` is a member of the object managed by `rhs` or is an alias (e.g., downcast) of `rhs.get()`.

			Examples:
				--------------------
				static struct Foo{
					int i;
					double d;
				}
				SharedPtr!Foo foo = SharedPtr!Foo.make(42, 3.14);

				auto x = SharedPtr!double(foo, &foo.d);
				assert(foo.useCount == 2);
				assert(foo.get == 3.14);
				--------------------
		*/
		public this(Rhs, Elm, this This)(auto ref scope Rhs rhs, Elm element)@trusted	//if rhs is rvalue then dtor is called on empty rhs
		if(    isSharedPtr!Rhs
			&& is(Elm : GetElementReferenceType!This)
			&& isAliasable!(Rhs, This)
			&& !weakLock!(Rhs, This)
			&& !is(Rhs == shared)
		){
			this._control = rhs._control;
			this._element = element;

			static if(isRef!rhs || (isWeak && !Rhs.isWeak)){
				if(this._control !is null)
					rhs._control.add!isWeak;
			}
			else{
				rhs._const_reset();
			}
		}


		/**
			Constructs a `SharedPtr` which shares ownership of the object managed by `rhs`.

			If rhs manages no object, this manages no object too.
			If rhs if rvalue then ownership is moved.
			The template overload doesn't participate in overload resolution if ElementType of `typeof(rhs)` is not implicitly convertible to `ElementType`.
			If rhs if `WeakType` then this ctor is equivalent to `this(rhs.lock())`.

			Examples:
				--------------------
				{
					SharedPtr!long x = SharedPtr!long.make(123);
					assert(x.useCount == 1);

					SharedPtr!long a = x;	      //lvalue copy ctor
					assert(a == x);

					const SharedPtr!long b = x;   //lvalue copy ctor
					assert(b == x);

					SharedPtr!(const long) c = x; //lvalue ctor
					assert(c == x);

					const SharedPtr!long d = b;   //lvalue ctor
					assert(d == x);

					assert(x.useCount == 5);
				}

				{
					import core.lifetime : move;
					SharedPtr!long x = SharedPtr!long.make(123);
					assert(x.useCount == 1);

					SharedPtr!long a = move(x);        //rvalue copy ctor
					assert(a.useCount == 1);

					const SharedPtr!long b = move(a);  //rvalue copy ctor
					assert(b.useCount == 1);

					SharedPtr!(const long) c = b.load;  //rvalue ctor
					assert(c.useCount == 2);

					const SharedPtr!long d = move(c);  //rvalue ctor
					assert(d.useCount == 2);
				}

				{
					import core.lifetime : move;
					auto u = UniquePtr!(long, SharedControlBlock).make(123);

					SharedPtr!long s = move(u);        //rvalue copy ctor
					assert(s != null);
					assert(s.useCount == 1);

					SharedPtr!long s2 = UniquePtr!(long, SharedControlBlock).init;
					assert(s2 == null);
				}

				{
					import core.lifetime : move;
					auto rc = RcPtr!(long).make(123);
					assert(rc.useCount == 1);

					SharedPtr!long s = rc;
					assert(s != null);
					assert(s.useCount == 2);
					assert(rc.useCount == 2);

					SharedPtr!long s2 = RcPtr!(long).init;
					assert(s2 == null);
				}
				--------------------
		*/
		public this(Rhs, this This)(auto ref scope Rhs rhs)@trusted //if rhs is rvalue then dtor is called on empty rhs
		if(    isSmartPtr!Rhs   //(isSharedPtr!Rhs || isRcPtr!Rhs || isIntrusivePtr!Rhs)
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
					SharedPtr!long x = SharedPtr!long.make(1);

					assert(x.useCount == 1);
					x = null;
					assert(x.useCount == 0);
					assert(x == null);
				}

				{
					SharedPtr!(shared long) x = SharedPtr!(shared long).make(1);

					assert(x.useCount == 1);
					x = null;
					assert(x.useCount == 0);
					assert(x == null);
				}

				{
					shared SharedPtr!(long) x = SharedPtr!(shared long).make(1);

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
				this.lockSmartPtr!(
					(ref scope self) => self.opAssign!order(null)
				)();
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
			If `rhs` is rvalue then move-assigns a `SharedPtr` from `rhs`

			Examples:
				--------------------
				{
					SharedPtr!long px1 = SharedPtr!long.make(1);
					SharedPtr!long px2 = SharedPtr!long.make(2);

					assert(px2.useCount == 1);
					px1 = px2;
					assert(*px1 == 2);
					assert(px2.useCount == 2);
				}


				{
					SharedPtr!long px = SharedPtr!long.make(1);
					SharedPtr!(const long) pcx = SharedPtr!long.make(2);

					assert(px.useCount == 1);
					pcx = px;
					assert(*pcx == 1);
					assert(pcx.useCount == 2);

				}


				{
					const SharedPtr!long cpx = SharedPtr!long.make(1);
					SharedPtr!(const long) pcx = SharedPtr!long.make(2);

					assert(pcx.useCount == 1);
					pcx = cpx;
					assert(*pcx == 1);
					assert(pcx.useCount == 2);

				}

				{
					SharedPtr!(immutable long) pix = SharedPtr!(immutable long).make(123);
					SharedPtr!(const long) pcx = SharedPtr!long.make(2);

					assert(pix.useCount == 1);
					pcx = pix;
					assert(*pcx == 123);
					assert(pcx.useCount == 2);

				}
				--------------------
		*/
		public void opAssign(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(auto ref scope Rhs desired)scope
		if(    isSharedPtr!Rhs
			&& isAssignable!(desired, This)
			&& !is(Rhs == shared)
		){
			// shared assign:
			static if(is(This == shared)){
				this.lockSmartPtr!(
					(ref scope self, auto ref scope Rhs x) => self.opAssign!order(forward!x)
				)(forward!desired);
			}
			// copy assign or non identity move assign:
			else static if(isRef!desired || !is(This == Rhs)){
				static if(isRef!desired && (This.isWeak != Rhs.isWeak)){
					if((()@trusted => cast(const void*)&desired is cast(const void*)&this)())
						return;
				}

				this._release();

				auto tmp = This(forward!desired);

				()@trusted{
					this._set_element(tmp._element);
					this._control = tmp._control;

					tmp._const_set_counter(null);
				}();
			}
			//identity move assign:   //separate case for core.lifetime.move
			else{
				static assert(isMoveAssignable!(Rhs, This));
				static assert(!isRef!desired);

				this._release();

				()@trusted{
					this._control = desired._control;
					this._set_element(desired._element);

					desired._const_set_counter(null);
				}();

			}
		}

		///ditto
		public void opAssign(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(auto ref scope Rhs desired)scope
		if(    (isSmartPtr!Rhs && !isSharedPtr!Rhs) //(isRcPtr!Rhs || isIntrusivePtr!Rhs)
			&& isAssignable!(desired, This)
			&& !is(Rhs == shared)
		){
			this.opAssign!order(UnqualSmartPtr!This(forward!desired));
		}



		/**
			Constructs an object of type `ElementType` and wraps it in a `SharedPtr` using args as the parameter list for the constructor of `ElementType`.

			The object is constructed as if by the expression `emplace!ElementType(_payload, forward!args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
			The storage is typically larger than `ElementType.sizeof` in order to use one allocation for both the control block and the `ElementType` object.

			Examples:
				--------------------
				{
					SharedPtr!long a = SharedPtr!long.make();
					assert(a.get == 0);

					SharedPtr!(const long) b = SharedPtr!long.make(2);
					assert(b.get == 2);
				}

				{
					static struct Struct{
						int i = 7;

						this(int i)pure nothrow @safe @nogc{
							this.i = i;
						}
					}

					SharedPtr!Struct s1 = SharedPtr!Struct.make();
					assert(s1.get.i == 7);

					SharedPtr!Struct s2 = SharedPtr!Struct.make(123);
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

					SharedPtr!Interface x = SharedPtr!Class.make(3);
					//assert(x.dynTo!Class.get.i == 3);
				}
				--------------------
		*/
		public static auto make(AllocatorType = DefaultAllocator, bool supportGC = platformSupportGC, Args...)(auto ref Args args)
		if(!isDynamicArray!ElementType){

			alias ReturnType = SharedPtr!(
				ElementType,
				.DestructorType!(
					ElementDestructorType,
					DestructorType,
					DestructorAllocatorType!AllocatorType
				),
				ControlType
			);

			auto m = ReturnType.MakeEmplace!(AllocatorType, supportGC).make(AllocatorType.init, forward!(args));

			return (m is null)
				? ReturnType(null)
				: ReturnType(m.base, m.get);
		}

		/**
			Constructs a `SharedPtr` with `element` as the pointer to the managed object.

			Uses the specified `deleter` as the deleter. The expression `deleter(element)` must be well formed, have well-defined behavior and not throw any exceptions.
			The construction of `deleter` and of the stored deleter from d must not throw exceptions.

			Examples:
				--------------------
				long deleted = -1;
				auto x = SharedPtr!long.make(new long(123), (long* data){
					deleted = *data;
				});
				assert(deleted == -1);
				assert(*x == 123);

				x = null;
				assert(deleted == 123);
				--------------------
		*/
		public static auto make(AllocatorType = DefaultAllocator, bool supportGC = platformSupportGC, DeleterType)(ElementReferenceType element, DeleterType deleter)
		if(isCallable!DeleterType){

			alias ReturnType = SharedPtr!(
				ElementType,
				.DestructorType!(
					ElementDestructorType,
					DestructorType,
					DestructorAllocatorType!AllocatorType,
					DestructorDeleterType!(ElementType, DeleterType)
				),
				ControlType
			);

			auto m = ReturnType.MakeDeleter!(DeleterType, AllocatorType, supportGC).make(AllocatorType.init, forward!deleter, forward!element);

			return (m is null)
				? ReturnType(null)
				: ReturnType(m.base, m.get);
		}


		/**
			Constructs an object of array type `ElementType` including its array elements and wraps it in a `SharedPtr`.

			Parameters:
				n = Array length

				args = parameters for constructor for each array element.

			The array elements are constructed as if by the expression `emplace!ElementType(_payload, args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
			The storage is typically larger than `ElementType.sizeof * n` in order to use one allocation for both the control block and the each array element.

			Examples:
				--------------------
				auto arr = SharedPtr!(long[]).make(6, -1);
				assert(arr.length == 6);
				assert(arr.get.length == 6);

				import std.algorithm : all;
				assert(arr.get.all!(x => x == -1));

				for(long i = 0; i < 6; ++i)
					arr.get[i] = i;

				assert(arr.get == [0, 1, 2, 3, 4, 5]);
				--------------------
		*/
		public static auto make(AllocatorType = DefaultAllocator, bool supportGC = platformSupportGC, Args...)(const size_t n, auto ref Args args)
		if(isDynamicArray!ElementType){

			alias ReturnType = SharedPtr!(
				ElementType,
				.DestructorType!(
					ElementDestructorType,
					DestructorType,
					DestructorAllocatorType!AllocatorType
				),
				ControlType
			);
			auto m = ReturnType.MakeDynamicArray!(AllocatorType, supportGC).make(AllocatorType.init, n, forward!(args));

			return (m is null)
				? ReturnType(null)
				: ReturnType(m.base, m.get);
		}



		/**
			Constructs an object of type `ElementType` and wraps it in a `SharedPtr` using args as the parameter list for the constructor of `ElementType`.

			The object is constructed as if by the expression `emplace!ElementType(_payload, forward!args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
			The storage is typically larger than `ElementType.sizeof` in order to use one allocation for both the control block and the `ElementType` object.

			Examples:
				--------------------
				auto a = allocatorObject(Mallocator.instance);
				{
					auto a = SharedPtr!long.alloc(a);
					assert(a.get == 0);

					auto b = SharedPtr!(const long).alloc(a, 2);
					assert(b.get == 2);
				}

				{
					static struct Struct{
						int i = 7;

						this(int i)pure nothrow @safe @nogc{
							this.i = i;
						}
					}

					auto s1 = SharedPtr!Struct.alloc(a);
					assert(s1.get.i == 7);

					auto s2 = SharedPtr!Struct.alloc(a, 123);
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

					SharedPtr!Interface x = SharedPtr!Class.alloc(a, 3);
					//assert(x.dynTo!Class.get.i == 3);
				}
				--------------------
		*/
		public static auto alloc(bool supportGC = platformSupportGC, AllocatorType, Args...)(AllocatorType a, auto ref Args args)
		if(!isDynamicArray!ElementType){

			alias ReturnType = SharedPtr!(
				ElementType,
				.DestructorType!(
					ElementDestructorType,
					DestructorType,
					DestructorAllocatorType!AllocatorType
				),
				ControlType
			);
			auto m = ReturnType.MakeEmplace!(AllocatorType, supportGC).make(forward!(a, args));

			return (m is null)
				? ReturnType(null)
				: ReturnType(m.base, m.get);
		}


		/**
			Constructs a `SharedPtr` with `element` as the pointer to the managed object using `allocator` with state.

			Uses the specified `deleter` as the deleter. The expression `deleter(element)` must be well formed, have well-defined behavior and not throw any exceptions.
			The construction of `deleter` and of the stored deleter from d must not throw exceptions.

			Examples:
				--------------------
				auto a = allocatorObject(Mallocator.instance);

				long deleted = -1;
				auto x = SharedPtr!long.make(new long(123), (long* data){
					deleted = *data;
				}, a);
				assert(deleted == -1);
				assert(*x == 123);

				x = null;
				assert(deleted == 123);
				--------------------
		*/
		public static auto alloc(bool supportGC = platformSupportGC, AllocatorType, DeleterType)(AllocatorType allocator, ElementReferenceType element, DeleterType deleter)
		if(isCallable!DeleterType){

			alias ReturnType = SharedPtr!(
				ElementType,
				.DestructorType!(
					ElementDestructorType,
					DestructorType,
					DestructorAllocatorType!AllocatorType,
					DestructorDeleterType!(ElementType, DeleterType)
				),
				ControlType
			);
			auto m = ReturnType.MakeDeleter!(DeleterType, AllocatorType, supportGC).make(forward!allocator, forward!deleter, forward!element);

			return (m is null)
				? ReturnType(null)
				: ReturnType(m.base, m.get);
		}



		/**
			Constructs an object of array type `ElementType` including its array elements and wraps it in a `SharedPtr`.

			Parameters:
				n = Array length

				args = parameters for constructor for each array element.

			The array elements are constructed as if by the expression `emplace!ElementType(_payload, args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
			The storage is typically larger than `ElementType.sizeof * n` in order to use one allocation for both the control block and the each array element.

			Examples:
				--------------------
				auto a = allocatorObject(Mallocator.instance);
				auto arr = SharedPtr!(long[], DestructorType!(typeof(a))).alloc(a, 6, -1);
				assert(arr.length == 6);
				assert(arr.get.length == 6);

				import std.algorithm : all;
				assert(arr.get.all!(x => x == -1));

				for(long i = 0; i < 6; ++i)
					arr.get[i] = i;

				assert(arr.get == [0, 1, 2, 3, 4, 5]);
				--------------------
		*/
		public static auto alloc(bool supportGC = platformSupportGC, AllocatorType, Args...)(AllocatorType a, const size_t n, auto ref Args args)
		if(isDynamicArray!ElementType){

			alias ReturnType = SharedPtr!(
				ElementType,
				.DestructorType!(
					ElementDestructorType,
					DestructorType,
					DestructorAllocatorType!AllocatorType
				),
				ControlType
			);
			auto m = ReturnType.MakeDynamicArray!(AllocatorType, supportGC).make(forward!(a, n, args));

			return (m is null)
				? ReturnType(null)
				: ReturnType(m.base, m.get);
		}



		/**
			Returns the number of different `SharedPtr` instances

			Returns the number of different `SharedPtr` instances (`this` included) managing the current object or `0` if there is no managed object.

			Examples:
				--------------------
				SharedPtr!long x = null;

				assert(x.useCount == 0);

				x = SharedPtr!long.make(123);
				assert(x.useCount == 1);

				auto y = x;
				assert(x.useCount == 2);

				auto w1 = x.weak;    //weak ptr
				assert(x.useCount == 2);

				SharedPtr!long.WeakType w2 = x;   //weak ptr
				assert(x.useCount == 2);

				y = null;
				assert(x.useCount == 1);

				x = null;
				assert(x.useCount == 0);
				assert(w1.useCount == 0);
				--------------------
		*/
		public @property ControlType.Shared useCount(this This)()const scope nothrow @safe @nogc{
			static if(is(This == shared)){
				return this.lockSmartPtr!(
					(ref scope self) => self.useCount()
				)();
			}
			else{
				const control = this._control;

				return (control is null)
					? 0
					: control.count!false + 1;
			}

		}


		/**
			Returns the number of different `SharedPtr.WeakType` instances

			Returns the number of different `SharedPtr.WeakType` instances (`this` included) managing the current object or `0` if there is no managed object.

			Examples:
				--------------------
				SharedPtr!long x = null;
				assert(x.useCount == 0);
				assert(x.weakCount == 0);

				x = SharedPtr!long.make(123);
				assert(x.useCount == 1);
				assert(x.weakCount == 0);

				auto w = x.weak();
				assert(x.useCount == 1);
				assert(x.weakCount == 1);
				--------------------
		*/
		public @property ControlType.Weak weakCount(this This)()const scope nothrow @safe @nogc{

			static if(is(This == shared)){
				return this.lockSmartPtr!(
					(ref scope self) => self.weakCount()
				)();
			}
			else{
				const control = this._control;

				return (control is null)
					? 0
					: control.count!true;
			}

		}



		/**
			Swap `this` with `rhs`

			Examples:
				--------------------
				{
					SharedPtr!long a = SharedPtr!long.make(1);
					SharedPtr!long b = SharedPtr!long.make(2);
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
			auto control = this._control;
			auto element = this._element;

			this._control = rhs._control;
			this._set_element(rhs._element);

			rhs._control = control;
			rhs._set_element(element);
		}



		/**
			Returns the non `shared` `SharedPtr` pointer pointed-to by `shared` `this`.

			Examples:
				--------------------
				shared SharedPtr!(long) x = SharedPtr!(shared long).make(123);

				{
					SharedPtr!(shared long) y = x.load();
					assert(y.useCount == 2);

					assert(y.get == 123);
				}
				--------------------
		*/
		public UnqualSmartPtr!This load(MemoryOrder order = MemoryOrder.seq, this This)()scope{

			static if(is(This == shared)){
				return this.lockSmartPtr!(
					(ref scope self) => self.load!order()
				)();
			}
			else{
				return typeof(return)(this);
			}
		}



		/**
			Stores the non `shared` `SharedPtr` parameter `ptr` to `this`.

			If `this` is shared then operation is atomic or guarded by mutex.

			Template parameter `order` has type `core.atomic.MemoryOrder`.

			Examples:
				--------------------
				//null store:
				{
					shared x = SharedPtr!(shared long).make(123);
					assert(x.load.get == 123);

					x.store(null);
					assert(x.useCount == 0);
					assert(x.load == null);
				}

				//rvalue store:
				{
					shared x = SharedPtr!(shared long).make(123);
					assert(x.load.get == 123);

					x.store(SharedPtr!(shared long).make(42));
					assert(x.load.get == 42);
				}

				//lvalue store:
				{
					shared x = SharedPtr!(shared long).make(123);
					auto y = SharedPtr!(shared long).make(42);

					assert(x.load.get == 123);
					assert(y.load.get == 42);

					x.store(y);
					assert(x.load.get == 42);
					assert(x.useCount == 2);
				}
				--------------------
		*/
		alias store = opAssign;



		/**
			Stores the non `shared` `SharedPtr` pointer ptr in the `shared(SharedPtr)` pointed to by `this` and returns the value formerly pointed-to by this, atomically or with mutex.

			Examples:
				--------------------
				//lvalue exchange
				{
					shared x = SharedPtr!(shared long).make(123);
					auto y = SharedPtr!(shared long).make(42);

					auto z = x.exchange(y);

					assert(x.load.get == 42);
					assert(y.get == 42);
					assert(z.get == 123);
				}

				//rvalue exchange
				{
					shared x = SharedPtr!(shared long).make(123);
					auto y = SharedPtr!(shared long).make(42);

					import core.lifetime : move;
					auto z = x.exchange(move(y));

					assert(x.load.get == 42);
					assert(y == null);
					assert(z.get == 123);
				}

				//null exchange (same as move)
				{
					shared x = SharedPtr!(shared long).make(123);

					auto z = x.exchange(null);

					assert(x.load == null);
					assert(z.get == 123);
				}

				//swap:
				{
					shared x = SharedPtr!(shared long).make(123);
					auto y = SharedPtr!(shared long).make(42);

					//opAssign is same as store
					import core.lifetime : move;
					y = x.exchange(move(y));

					assert(x.load.get == 42);
					assert(y.get == 123);
				}
				--------------------
		*/
		public SharedPtr exchange(MemoryOrder order = MemoryOrder.seq, this This)(typeof(null))scope
		if(isMutable!This){

			static if(is(This == shared))
				return this.lockSmartPtr!(
					(ref scope self) => self.exchange!order(null)
				)();
			else{
				return this._move;
			}
		}

		/// ditto
		public SharedPtr exchange(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(scope Rhs ptr)scope
		if(    isSharedPtr!Rhs
			&& isMoveAssignable!(Rhs, This)
			&& !is(Rhs == shared)
		){
			static if(is(This == shared))
				return this.lockSmartPtr!(
					(ref scope self, Rhs x) => self.exchange!order(x._move)
				)(ptr._move);
			else{
				auto result = this._move;

				return()@trusted{
					this = ptr._move;
					return result._move;
				}();
			}
		}



		/**
			Same as `compareExchange`.

			More info in c++ `std::atomic<std::shared_ptr>`.
		*/
		alias compareExchangeStrong = compareExchange;



		/**
			Same as `compareExchange`.

			More info in c++ `std::atomic<std::shared_ptr>`.
		*/
		alias compareExchangeWeak = compareExchange;



		/**
			Compares the `SharedPtr` pointers pointed-to by `this` and `expected`.

			If they are equivalent (store the same pointer value, and either share ownership of the same object or are both empty), assigns `desired` into `this` using the memory ordering constraints specified by `success` and returns `true`.
			If they are not equivalent, assigns `this` into `expected` using the memory ordering constraints specified by `failure` and returns `false`.

			More info in c++ std::atomic<std::shared_ptr>.

			Examples:
				--------------------
				//fail
				{
					SharedPtr!long a = SharedPtr!long.make(123);
					SharedPtr!long b = SharedPtr!long.make(42);
					SharedPtr!long c = SharedPtr!long.make(666);

					a.compareExchange(b, c);

					assert(*a == 123);
					assert(*b == 123);
					assert(*c == 666);

				}

				//success
				{
					SharedPtr!long a = SharedPtr!long.make(123);
					SharedPtr!long b = a;
					SharedPtr!long c = SharedPtr!long.make(666);

					a.compareExchange(b, c);

					assert(*a == 666);
					assert(*b == 123);
					assert(*c == 666);
				}

				//shared fail
				{
					shared SharedPtr!(shared long) a = SharedPtr!(shared long).make(123);
					SharedPtr!(shared long) b = SharedPtr!(shared long).make(42);
					SharedPtr!(shared long) c = SharedPtr!(shared long).make(666);

					a.compareExchange(b, c);

					auto tmp = a.exchange(null);
					assert(*tmp == 123);
					assert(*b == 123);
					assert(*c == 666);
				}

				//shared success
				{
					SharedPtr!(shared long) b = SharedPtr!(shared long).make(123);
					shared SharedPtr!(shared long) a = b;
					SharedPtr!(shared long) c = SharedPtr!(shared long).make(666);

					a.compareExchange(b, c);

					auto tmp = a.exchange(null);
					assert(*tmp == 666);
					assert(*b == 123);
					assert(*c == 666);
				}

				--------------------
		*/
		public bool compareExchange
			(MemoryOrder success = MemoryOrder.seq, MemoryOrder failure = success, E, D, this This)
			(ref scope E expected, scope D desired)scope //@trusted
		if(    isSharedPtr!E && !is(E == shared)
			&& isSharedPtr!D && !is(D == shared)
			&& isMoveAssignable!(D, This)
			&& isCopyAssignable!(This, E)
		){
			static if(is(This == shared)){
				import btl.internal.mutex : getMutex;

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
			Creates a new non weak `SharedPtr` that shares ownership of the managed object (must be `SharedPtr.WeakType`).

			If there is no managed object, i.e. this is empty or this is `expired`, then the returned `SharedPtr` is empty.
			Method exists only if `SharedPtr` is `isWeak`

			Examples:
				--------------------
				{
					SharedPtr!long x = SharedPtr!long.make(123);

					auto w = x.weak;    //weak ptr

					SharedPtr!long y = w.lock;

					assert(x == y);
					assert(x.useCount == 2);
					assert(y.get == 123);
				}

				{
					SharedPtr!long x = SharedPtr!long.make(123);

					auto w = x.weak;    //weak ptr

					assert(w.expired == false);

					x = SharedPtr!long.make(321);

					assert(w.expired == true);

					SharedPtr!long y = w.lock;

					assert(y == null);
				}
				--------------------
		*/
		public SharedType lock()()scope
		if(isCopyConstructable!(typeof(this), SharedType)){
			return typeof(return)(this);
		}



		/**
			Equivalent to `useCount() == 0` (must be `SharedPtr.WeakType`).

			Method exists only if `SharedPtr` is `isWeak`

			Examples:
				--------------------
				{
					SharedPtr!long x = SharedPtr!long.make(123);

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
					SharedPtr!long x = SharedPtr!long.make(123);
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

				Doesn't increment useCount, is inherently unsafe.

				Examples:
					--------------------
					SharedPtr!long x = SharedPtr!long.make(123);
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
				public @property inout(ElementType) get()inout return pure nothrow @system @nogc{
					assert((this._element is null) <= (this._control is null));
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
					assert((this._element is null) <= (this._control is null));
					return *cast(ElementType*)this._element;
				}

				/// ditto
				public @property ref const(inout(ElementType)) get()const inout return pure nothrow @safe @nogc{
					assert((this._element is null) <= (this._control is null));
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
					SharedPtr!long x = SharedPtr!long.make(123);
					assert(*x.element == 123);

					x.get = 321;
					assert(*x.element == 321);

					const y = x;
					assert(*y.element == 321);
					assert(*x.element == 321);

					static assert(is(typeof(y.element) == const(long)*));
				}

				{
					auto s = SharedPtr!long.make(42);
					const w = s.weak;

					assert(*w.element == 42);

					s = null;
					assert(w.element is null);
				}

				{
					auto s = SharedPtr!long.make(42);
					auto w = s.weak;

					scope const p = w.element;

					s = null;
					assert(w.element is null);

					assert(p !is null); //p is dangling pointer!
				}
				--------------------
		*/
		public @property ElementReferenceTypeImpl!(inout ElementType) element()inout return pure nothrow @system @nogc{
			assert((this._element is null) <= (this._control is null));
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
				auto x = SharedPtr!(int[]).make(10, -1);
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
				SharedPtr!long x = SharedPtr!long.make(123);
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

			BUG: qualfied variable of struct with dtor cannot be inside other struct (generated dtor will use opCast to mutable before dtor call ). opCast is renamed to opCastImpl

			Examples:
				--------------------
				SharedPtr!long x = SharedPtr!long.make(123);
				assert(cast(bool)x);    //explicit cast
				assert(x);              //implicit cast
				x = null;
				assert(!cast(bool)x);   //explicit cast
				assert(!x);             //implicit cast
				--------------------
		*/
		public bool opCastImpl(To : bool)()const scope pure nothrow @safe @nogc
		if(is(To : bool)){ //docs
			return (this != null);
		}


		/**
			Cast `this` to different type `To` when `isSharedPtr!To`.

			BUG: qualfied variable of struct with dtor cannot be inside other struct (generated dtor will use opCast to mutable before dtor call ). opCast is renamed to opCastImpl

			Examples:
				--------------------
				SharedPtr!long x = SharedPtr!long.make(123);
				auto y = cast(SharedPtr!(const long))x;
				auto z = cast(const SharedPtr!long)x;
				auto u = cast(const SharedPtr!(const long))x;
				assert(x.useCount == 4);
				--------------------
		*/
		public To opCastImpl(To, this This)()scope
		if(isSharedPtr!To && !is(This == shared)){

			return To(this);
		}


		/**
			Operator == and != .
			Compare pointers.

			Examples:
				--------------------
				{
					SharedPtr!long x = SharedPtr!long.make(0);
					assert(x != null);
					x = null;
					assert(x == null);
				}

				{
					SharedPtr!long x = SharedPtr!long.make(123);
					SharedPtr!long y = SharedPtr!long.make(123);
					assert(x == x);
					assert(y == y);
					assert(x != y);
				}

				{
					SharedPtr!long x;
					SharedPtr!(const long) y;
					assert(x == x);
					assert(y == y);
					assert(x == y);
				}

				{
					SharedPtr!long x = SharedPtr!long.make(123);
					SharedPtr!long y = SharedPtr!long.make(123);
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
		public bool opEquals(Rhs)(auto ref scope const Rhs rhs)const @safe scope pure nothrow @nogc
		if(isSharedPtr!Rhs && !is(Rhs == shared)){
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
			Operators <, <=, >, >= for `SharedPtr`.

			Compare address of payload.

			Examples:
				--------------------
				{
					const a = SharedPtr!long.make(42);
					const b = SharedPtr!long.make(123);
					const n = SharedPtr!long.init;

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
					const a = SharedPtr!long.make(42);
					const b = SharedPtr!long.make(123);

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
		public sizediff_t opCmp(Rhs)(auto ref scope const Rhs rhs)const @trusted scope pure nothrow @nogc
		if(isSharedPtr!Rhs && !is(Rhs == shared)){
			return this.opCmp(rhs._element);
		}



		/**
			Generate hash

			Return:
				Address of payload as `size_t`

			Examples:
				--------------------
				{
					SharedPtr!long x = SharedPtr!long.make(123);
					SharedPtr!long y = SharedPtr!long.make(123);
					assert(x.toHash == x.toHash);
					assert(y.toHash == y.toHash);
					assert(x.toHash != y.toHash);
					SharedPtr!(const long) z = x;
					assert(x.toHash == z.toHash);
				}
				{
					SharedPtr!long x;
					SharedPtr!(const long) y;
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



		private ControlType* _control;
		private ElementReferenceType _element;

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

		private void _const_set_counter(ControlType* c)const pure nothrow @system @nogc{
			auto self = cast(Unqual!(typeof(this))*)&this;

			self._control = c;
		}

		private void _release()scope{
			if(false){
				DestructorType dt;
				dt(null);
			}

			import std.traits : hasIndirections;
			import core.memory : GC;

			if(this._control !is null)
				this._control.release!isWeak;
		}

		private void _reset()scope pure nothrow @system @nogc{
			this._control = null;
			this._set_element(null);
		}

		private void _const_reset()scope const pure nothrow @system @nogc{
			this._const_set_counter(null);
			this._const_set_element(null);
		}

		package auto _move()@trusted{
			auto e = this._element;
			auto c = this._control;
			this._const_reset();

			return typeof(this)(c, e);
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

		private alias MakeDeleter(DeleterType, AllocatorType, bool supportGC) = .MakeDeleter!(
			_Type,
			_DestructorType,
			_ControlType,
			DeleterType,
			AllocatorType,
			supportGC
		);

		package alias SmartPtr = .SmartPtr;

		/**/
		package alias ChangeElementType(T) = SharedPtr!(
			CopyTypeQualifiers!(ElementType, T),
			DestructorType,
			ControlType,
			isWeak
		);
	}

}



/// Alias to `SharedPtr` with different order of template parameters
public template SharedPtr(
	_Type,
	_ControlType,
	_DestructorType = DestructorType!_Type,
	bool _weakPtr = false
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){
	alias SharedPtr = .SharedPtr!(_Type, _DestructorType, _ControlType, _weakPtr);
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
		SharedPtr!long a = SharedPtr!long.make(42);
		assert(a.useCount == 1);

		SharedPtr!(const long) b = a;
		assert(a.useCount == 2);

		SharedPtr!long.WeakType w = a.weak; //or WeakPtr!long
		assert(a.useCount == 2);
		assert(a.weakCount == 1);

		SharedPtr!long c = w.lock;
		assert(a.useCount == 3);
		assert(a.weakCount == 1);

		assert(*c == 42);
		assert(c.get == 42);
	}

	///polymorphism and aliasing:
	{
		///create SharedPtr
		SharedPtr!Foo foo = SharedPtr!Bar.make(42, 3.14);
		SharedPtr!Zee zee = SharedPtr!Zee.make(42, 3.14, false);

		///dynamic cast:
		SharedPtr!Bar bar = dynCast!Bar(foo);
		assert(bar != null);
		assert(foo.useCount == 2);

		///this doesnt work because Foo destructor attributes are more restrictive then Zee's:
		//SharedPtr!Foo x = zee;

		///this does work:
		SharedPtr!(Foo, DestructorType!(Foo, Zee)) x = zee;
		assert(zee.useCount == 2);

		///aliasing (shared ptr `d` share ref counting with `bar`):
		SharedPtr!double d = SharedPtr!double(bar, &bar.get.d);
		assert(d != null);
		assert(*d == 3.14);
		assert(foo.useCount == 3);
	}


	///multi threading:
	{
		///create SharedPtr with atomic ref counting
		SharedPtr!(shared Foo) foo = SharedPtr!(shared Bar).make(42, 3.14);

		///this doesnt work:
		//foo.get.i += 1;

		import core.atomic : atomicFetchAdd;
		atomicFetchAdd(foo.get.i, 1);
		assert(foo.get.i == 43);


		///creating `shared(SharedPtr)`:
		shared SharedPtr!(shared Bar) bar = share(dynCast!Bar(foo));

		///`shared(SharedPtr)` is not lock free but `RcPtr` is lock free.
		static assert(typeof(bar).isLockFree == false);

		///multi thread operations (`load`, `store`, `exchange` and `compareExchange`):
		SharedPtr!(shared Bar) bar2 = bar.load();
		assert(bar2 != null);
		assert(bar2.useCount == 3);

		SharedPtr!(shared Bar) bar3 = bar.exchange(null);
		assert(bar3 != null);
		assert(bar3.useCount == 3);
	}

	///dynamic array:
	{
		import std.algorithm : all, equal;

		SharedPtr!(long[]) a = SharedPtr!(long[]).make(10, -1);
		assert(a.length == 10);
		assert(a.get.length == 10);
		assert(a.get.all!(x => x == -1));

		for(long i = 0; i < a.length; ++i){
			a.get[i] = i;
		}
		assert(a.get[] == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

		///aliasing:
		SharedPtr!long a6 = SharedPtr!long(a, &a.get[6]);
		assert(*a6 == a.get[6]);
	}
}


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
		SharedPtr!(const Foo) foo =  SharedPtr!Foo.make(42);
		assert(foo.get.i == 42);
		assert(foo.useCount == 1);

		const SharedPtr!Foo foo2 = foo;
		assert(foo2.get.i == 42);
		assert(foo.useCount == 2);

	}

	//polymorphic classes:
	{
		SharedPtr!Foo foo = SharedPtr!Bar.make(42, 3.14);
		assert(foo != null);
		assert(foo.useCount == 1);
		assert(foo.get.i == 42);

		//dynamic cast:
		{
			SharedPtr!Bar bar = dynCast!Bar(foo);
			assert(foo.useCount == 2);

			assert(bar.get.i == 42);
			assert(bar.get.d == 3.14);
		}

	}

	//aliasing:
	{
		SharedPtr!Foo foo = SharedPtr!Bar.make(42, 3.14);
		assert(foo.useCount == 1);

		auto x = SharedPtr!int(foo, &foo.get.i);
		assert(foo.useCount == 2);
		assert(x.useCount == 2);

		assert(*x == 42);
	}

	//weak references:
	{
		auto x = SharedPtr!double.make(3.14);
		assert(x.useCount == 1);
		assert(x.weakCount == 0);

		auto w = x.weak();  //weak pointer
		assert(x.useCount == 1);
		assert(x.weakCount == 1);
		assert(*w.lock == 3.14);

		SharedPtr!double.WeakType w2 = x;
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
			auto arr = SharedPtr!(long[]).make(10, -1);

			assert(arr.length == 10);
			assert(arr.get.all!(x => x == -1));
		}

		{
			auto arr = SharedPtr!(long[]).make(8);
			assert(arr.length == 8);
			assert(arr.get.all!(x => x == long.init));
		}
	}

	//static array
	{
		import std.algorithm : all;

		{
			auto arr = SharedPtr!(long[4]).make(-1);
			assert(arr.get[].all!(x => x == -1));

		}

		{
			long[4] tmp = [0, 1, 2, 3];
			auto arr = SharedPtr!(long[4]).make(tmp);
			assert(arr.get[] == tmp[]);
		}
	}

}

///
pure nothrow @safe @nogc unittest{
	//make SharedPtr object
	static struct Foo{
		int i;

		this(int i)pure nothrow @safe @nogc{
			this.i = i;
		}
	}

	{
		auto foo = SharedPtr!Foo.make(42);
		auto foo2 = SharedPtr!Foo.make!Mallocator(42);  //explicit stateless allocator
	}

	{
		import std.experimental.allocator : make, dispose;

		static void deleter(long* x)pure nothrow @trusted @nogc{
			Mallocator.instance.dispose(x);
		}
		long* element = Mallocator.instance.make!long;

		auto x = SharedPtr!long.make(element, &deleter);
	}

	{
		auto arr = SharedPtr!(long[]).make(10); //dynamic array with length 10
		assert(arr.length == 10);
	}
}

///
nothrow unittest{
	//alloc SharedPtr object
	import std.experimental.allocator : make, dispose, allocatorObject;

	auto allocator = allocatorObject(Mallocator.instance);

	{
		auto x = SharedPtr!long.alloc(allocator, 42);
	}

	{
		static void deleter(long* x)pure nothrow @trusted @nogc{
			Mallocator.instance.dispose(x);
		}
		long* element = Mallocator.instance.make!long;
		auto x = SharedPtr!long.alloc(allocator, element, &deleter);
	}

	{
		auto arr = SharedPtr!(long[]).alloc(allocator, 10); //dynamic array with length 10
		assert(arr.length == 10);
	}

}



/**
	Weak pointer.

	Alias to `SharedPtr.WeakType`.
*/
public template WeakPtr(
	_Type,
	_DestructorType = DestructorType!_Type,
	_ControlType = ControlBlockDeduction!(_Type, SharedControlBlock),
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){
	alias WeakPtr = .SharedPtr!(_Type, _DestructorType, _ControlType, true);
}

/// ditto
public template WeakPtr(
	_Type,
	_ControlType,
	_DestructorType = DestructorType!_Type,
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){
	alias WeakPtr = .SharedPtr!(_Type, _DestructorType, _ControlType, true);
}



//make:
pure nothrow @nogc unittest{
	enum bool supportGC = true;

	//
	{
		auto s = SharedPtr!long.make(42);
	}

	{
		auto s = SharedPtr!long.make!(DefaultAllocator, supportGC)(42);
	}

	{
		auto s = SharedPtr!(long, shared(SharedControlBlock)).make!(DefaultAllocator, supportGC)(42);
	}

	// dynamic array:
	{
		auto s = SharedPtr!(long[]).make(10, 42);
		assert(s.length == 10);
	}
	{
		auto s = SharedPtr!(long[]).make!(DefaultAllocator, supportGC)(10, 42);
		assert(s.length == 10);
	}
	{
		auto s = SharedPtr!(long[], shared(SharedControlBlock)).make!(DefaultAllocator, supportGC)(10, 42);
		assert(s.length == 10);
	}

	// deleter:
	long x = 42;

	static void deleter(long* var)nothrow{
		(*var) += 1;
	}

	{
		auto s = SharedPtr!long.make(&x, &deleter);
	}
	assert(x == 43);

	{
		auto s = SharedPtr!(long).make!(DefaultAllocator, supportGC)(&x, &deleter);
	}
	assert(x == 44);

	{
		auto s = SharedPtr!(long, shared(SharedControlBlock)).make!(DefaultAllocator, supportGC)(&x, &deleter);
	}
	assert(x == 45);
}

//alloc:
nothrow unittest{
	import std.experimental.allocator : allocatorObject;

	auto a = allocatorObject(Mallocator.instance);
	enum bool supportGC = true;

	//
	{
		auto s = SharedPtr!long.alloc(a, 42);
	}

	{
		auto s = SharedPtr!long.alloc!supportGC(a, 42);
	}

	{
		auto s = SharedPtr!(long, shared(SharedControlBlock)).alloc!supportGC(a, 42);
	}

	// dynamic array:
	{
		auto s = SharedPtr!(long[]).alloc(a, 10, 42);
		assert(s.length == 10);
	}
	{
		auto s = SharedPtr!(long[]).alloc!supportGC(a, 10, 42);
		assert(s.length == 10);
	}
	{
		auto s = SharedPtr!(long[], shared(SharedControlBlock)).alloc!supportGC(a, 10, 42);
		assert(s.length == 10);
	}

	// deleter:
	long x = 42;

	static void deleter(long* var)nothrow{
		(*var) += 1;
	}

	{
		auto s = SharedPtr!long.alloc(a, &x, &deleter);
	}
	assert(x == 43);

	{
		auto s = SharedPtr!(long).alloc!supportGC(a, &x, &deleter);
	}
	assert(x == 44);

	{
		auto s = SharedPtr!(long, shared(SharedControlBlock)).alloc!supportGC(a, &x, &deleter);
	}
	assert(x == 45);
}



/**
	Dynamic cast for shared pointers if `ElementType` is class with D linkage.

	Move instance of `SharedPtr` whose stored pointer is obtained from `ptr`'s stored pointer using a dynaic cast expression.

	If `ptr` is null or dynamic cast fail then result `SharedPtr` is null.
	Otherwise, the new `SharedPtr` will share ownership with the initial value of `ptr`.
*/
public UnqualSmartPtr!Ptr.ChangeElementType!T dynCastMove(T, Ptr)(auto ref scope Ptr ptr)
if(    isSharedPtr!Ptr && !is(Ptr == shared) && !Ptr.isWeak
	&& isReferenceType!T && __traits(getLinkage, T) == "D"
	&& isReferenceType!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
	import std.traits : CopyTypeQualifiers;
	import core.lifetime : forward, move;

	alias Return = typeof(return);

	if(auto element = dynCastElement!T(ptr._element)){
		return (()@trusted => Return(move(ptr), element) )();
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
		SharedPtr!(const Foo) foo = SharedPtr!Bar.make(42, 3.14);
		assert(foo.get.i == 42);

		auto bar = dynCastMove!Bar(foo);
		assert(foo == null);
		assert(bar != null);
		assert(bar.get.d == 3.14);
		static assert(is(typeof(bar) == SharedPtr!(const Bar)));

		auto zee = dynCastMove!Zee(bar);
		assert(zee == null);
		assert(bar != null);
		static assert(is(typeof(zee) == SharedPtr!(const Zee)));
	}
}



/**
	Dynamic cast for shared pointers if `ElementType` is class with D linkage.

	Creates a new instance of `SharedPtr` whose stored pointer is obtained from `ptr`'s stored pointer using a dynaic cast expression.

	If `ptr` is null or dynamic cast fail then result `SharedPtr` is null.
	Otherwise, the new `SharedPtr` will share ownership with the initial value of `ptr`.
*/
public UnqualSmartPtr!Ptr.ChangeElementType!T dynCast(T, Ptr)(auto ref scope Ptr ptr)
if(    isSharedPtr!Ptr && !is(Ptr == shared) && !Ptr.isWeak
	&& isReferenceType!T && __traits(getLinkage, T) == "D"
	&& isReferenceType!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
	import std.traits : CopyTypeQualifiers;
	import core.lifetime : forward;

	alias Return = typeof(return);

	if(auto element = dynCastElement!T(ptr._element)){
		//return typeof(return)(forward!ptr, element);
		return (()@trusted => Return(forward!ptr, element) )();

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
		SharedPtr!(const Foo) foo = SharedPtr!Bar.make(42, 3.14);
		assert(foo.get.i == 42);

		auto bar = dynCast!Bar(foo);
		assert(bar != null);
		assert(bar.get.d == 3.14);
		static assert(is(typeof(bar) == SharedPtr!(const Bar)));

		auto zee = dynCast!Zee(foo);
		assert(zee == null);
		static assert(is(typeof(zee) == SharedPtr!(const Zee)));
	}
}


/**
	Create `SharedPtr` from parameter `ptr` of type `SharedPtr`, `RcPtr` or `IntrusivePtr`.
*/
auto sharedPtr(Ptr)(auto ref scope Ptr ptr)@trusted
if(!is(Ptr == shared)
	&& isSmartPtr!Ptr   //(isSharedPtr!Ptr || isRcPtr!Ptr || isIntrusivePtr!Ptr)
){
	import core.lifetime : forward;
	import std.traits : CopyTypeQualifiers;

	return SharedPtr!(
		GetElementType!Ptr,
		Ptr.DestructorType,
		GetControlType!Ptr,
		Ptr.isWeak
	)(forward!ptr, Forward.init);
}

///
pure nothrow @nogc unittest{
	import btl.autoptr.rc_ptr;
	import btl.autoptr.intrusive_ptr;

	import core.lifetime : move;
	//RcPtr -> SharedPtr:
	{
		auto x = RcPtr!long.make(42);
		assert(*x == 42);
		assert(x.useCount == 1);

		auto s = sharedPtr(x);
		assert(x.useCount == 2);

		import btl.autoptr.shared_ptr : isSharedPtr;
		static assert(isSharedPtr!(typeof(s)));

		auto s2 = sharedPtr(x.move);
		assert(s.useCount == 2);

		auto y = sharedPtr(RcPtr!long.init);
		assert(y == null);
	}

	//IntrusivePtr -> SharedPtr:
	{
		static class Foo{
			ControlBlock!(int, int) c;
			int i;

			this(int i)pure nothrow @safe @nogc{
				this.i = i;
			}
		}

		auto x = IntrusivePtr!Foo.make(42);
		//assert(x.get.i == 42);
		assert(x.useCount == 1);

		auto s = sharedPtr(x);
		assert(x.useCount == 2);

		import btl.autoptr.shared_ptr : isSharedPtr;
		static assert(isSharedPtr!(typeof(s)));

		auto s2 = sharedPtr(x.move);
		assert(s.useCount == 2);

		auto y = sharedPtr(IntrusivePtr!Foo.init);
		assert(y == null);
	}

	//SharedPtr -> SharedPtr:
	{
		auto a = SharedPtr!long.make(1);
		assert(a.useCount == 1);

		auto b = sharedPtr(a);
		assert(a.useCount == 2);

		auto c = sharedPtr(SharedPtr!long.make(2));
		assert(c.useCount == 1);
	}
}



/**
	Return `shared SharedPtr` pointing to same managed object like parameter `ptr`.

	Type of parameter `ptr` must be `SharedPtr` with `shared(ControlType)` and `shared`/`immutable` `ElementType` .
*/
public shared(Ptr) share(Ptr)(auto ref scope Ptr ptr)
if(isSharedPtr!Ptr){
	import core.lifetime : forward;

	static if(is(Ptr == shared)){
		return forward!ptr;
	}
	else{
		static assert(is(GetControlType!Ptr == shared) || is(GetControlType!Ptr == immutable),
			"`SharedPtr` has not shared/immutable ref counter `ControlType`."
		);

		static assert(is(GetElementType!Ptr == shared) || is(GetElementType!Ptr == immutable),
			"`SharedPtr` has not shared/immutable `ElementType`."
		);

		alias Result = shared(Ptr);

		return Result(forward!ptr, Forward.init);
	}
}

///
nothrow @nogc unittest{
	{
		auto x = SharedPtr!(shared long).make(123);
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
		auto x = SharedPtr!(long).make(123);
		assert(x.useCount == 1);

		///error `shared SharedPtr` need shared `ControlType` and shared `ElementType`.
		//shared s1 = share(x);

	}

}



/**
	Return `SharedPtr` pointing to first element of array managed by shared pointer `ptr`.
*/
public auto first(Ptr)(scope auto ref Ptr ptr)@trusted
if(    isSharedPtr!Ptr
	&& !is(Ptr == shared)
	&& is(Ptr.ElementType : T[], T)
){
	import std.traits : isDynamicArray, isStaticArray;
	import std.range : ElementEncodingType;
	import core.lifetime : forward;

	alias Result = UnqualSmartPtr!Ptr.ChangeElementType!(
		ElementEncodingType!(Ptr.ElementType)
	);

	if(ptr == null)
		return Result.init;

	static if(isDynamicArray!(Ptr.ElementType) || isStaticArray!(Ptr.ElementType)){
		auto ptr_element = ptr._element.ptr;
		return Result(forward!ptr, (()@trusted => ptr_element )());
		//assert(0);
	}
	else static assert(0, "no impl");
}

///
pure nothrow @nogc unittest{
	//copy
	{
		auto x = SharedPtr!(long[]).make(10, -1);
		assert(x.length == 10);

		auto y = first(x);
		static assert(is(typeof(y) == SharedPtr!long));
		assert(*y == -1);
		assert(x.useCount == 2);
	}

	{
		auto x = SharedPtr!(long[10]).make(-1);
		assert(x.get.length == 10);

		auto y = first(x);
		static assert(is(typeof(y) == SharedPtr!long));
		assert(*y == -1);
		assert(x.useCount == 2);
	}

	//move
	import core.lifetime : move;
	{
		auto x = SharedPtr!(long[]).make(10, -1);
		assert(x.length == 10);

		auto y = first(x.move);
		static assert(is(typeof(y) == SharedPtr!long));
		assert(*y == -1);
	}

	{
		auto x = SharedPtr!(long[10]).make(-1);
		assert(x.get.length == 10);

		auto y = first(x.move);
		static assert(is(typeof(y) == SharedPtr!long));
		assert(*y == -1);
	}
}


//local traits:
private{

	template isAliasable(From, To){
		enum bool isAliasable = true
			&& is(From.DestructorType : To.DestructorType)
			&& is(GetControlType!From* : GetControlType!To*);
	}

	//Constructable:
	template isMoveConstructable(From, To){
		import std.traits : CopyTypeQualifiers;

		enum bool isMoveConstructable = true
			&& isAliasable!(From, To)
			&& is(GetElementReferenceType!From : GetElementReferenceType!To);
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
	//this(SharedPtr, Element)
	pure nothrow @nogc unittest{
		{
			static struct Foo{
				int i;
				double d;
			}
			SharedPtr!Foo foo = SharedPtr!Foo.make(42, 3.14);

			auto x = SharedPtr!double(foo, &foo.get.d);
			assert(foo.useCount == 2);
			assert(x.get == 3.14);
		}

		{
			auto x1 = SharedPtr!long.make(1);

			const float f;
			auto x2 = const SharedPtr!float(x1, &f);

			assert(x1.useCount == 2);

			const double d;
			auto x3 = SharedPtr!(const double)((() => x1)(), &d);
			assert(x1.useCount == 3);

			/+shared bool b;
			auto x4 = SharedPtr!(shared bool)(x3, &b);
			assert(x1.useCount == 4);+/
		}

	}

	//copy ctor
	pure nothrow @nogc unittest{


		static struct Test{}

		import std.meta : AliasSeq;
		//alias Test = long;
		static foreach(alias ControlType; AliasSeq!(SharedControlBlock, shared SharedControlBlock)){{
			alias SPtr(T) = SharedPtr!(T, DestructorType!T, ControlType);

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
		SharedPtr!long x = null;

		assert(x == null);
		assert(x == SharedPtr!long.init);

	}


	//opAssign(SharedPtr)
	pure nothrow @nogc unittest{

		{
			SharedPtr!long px1 = SharedPtr!long.make(1);
			SharedPtr!long px2 = SharedPtr!long.make(2);

			assert(px2.useCount == 1);
			px1 = px2;
			assert(px1.get == 2);
			assert(px2.useCount == 2);
		}



		{
			SharedPtr!long px = SharedPtr!long.make(1);
			SharedPtr!(const long) pcx = SharedPtr!long.make(2);

			assert(px.useCount == 1);
			pcx = px;
			assert(pcx.get == 1);
			assert(pcx.useCount == 2);

		}


		{
			SharedPtr!(const long) pcx = SharedPtr!long.make(2);
			const SharedPtr!long pcx2 = pcx;

			assert(pcx.useCount == 2);

		}

		{
			SharedPtr!(immutable long) pix = SharedPtr!(immutable long).make(123);
			SharedPtr!(const long) pcx = SharedPtr!long.make(2);

			assert(pix.useCount == 1);
			pcx = pix;
			assert(pcx.get == 123);
			assert(pcx.useCount == 2);

		}
	}

	//opAssign(null)
	nothrow @safe @nogc unittest{
		{
			SharedPtr!long x = SharedPtr!long.make(1);

			assert(x.useCount == 1);
			x = null;
			assert(x.useCount == 0);
			assert(x == null);
		}

		{
			SharedPtr!(shared long) x = SharedPtr!(shared long).make(1);

			assert(x.useCount == 1);
			x = null;
			assert(x.useCount == 0);
			assert(x == null);
		}

		import btl.internal.mutex : supportMutex;
		static if(supportMutex){
			shared SharedPtr!(long) x = SharedPtr!(shared long).make(1);

			assert(x.useCount == 1);
			x = null;
			assert(x.useCount == 0);
			assert(x.load == null);
		}
	}

	//useCount
	pure nothrow @safe @nogc unittest{
		SharedPtr!long x = null;

		assert(x.useCount == 0);

		x = SharedPtr!long.make(123);
		assert(x.useCount == 1);

		auto y = x;
		assert(x.useCount == 2);

		auto w1 = x.weak;    //weak ptr
		assert(x.useCount == 2);

		SharedPtr!long.WeakType w2 = x;   //weak ptr
		assert(x.useCount == 2);

		y = null;
		assert(x.useCount == 1);

		x = null;
		assert(x.useCount == 0);
		assert(w1.useCount == 0);
	}

	//weakCount
	pure nothrow @safe @nogc unittest{

		SharedPtr!long x = null;
		assert(x.useCount == 0);
		assert(x.weakCount == 0);

		x = SharedPtr!long.make(123);
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
			shared x = SharedPtr!(shared long).make(123);
			assert(x.load.get == 123);

			x.store(null);
			assert(x.useCount == 0);
			assert(x.load == null);
		}

		//rvalue store:
		{
			shared x = SharedPtr!(shared long).make(123);
			assert(x.load.get == 123);

			x.store(SharedPtr!(shared long).make(42));
			assert(x.load.get == 42);
		}

		//lvalue store:
		{
			shared x = SharedPtr!(shared long).make(123);
			auto y = SharedPtr!(shared long).make(42);

			assert(x.load.get == 123);
			assert(y.load.get == 42);

			x.store(y);
			assert(x.load.get == 42);
			assert(x.useCount == 2);
		}
	}

	//load:
	nothrow @nogc unittest{

		shared SharedPtr!(long) x = SharedPtr!(shared long).make(123);

		import btl.internal.mutex : supportMutex;
		static if(supportMutex){
			SharedPtr!(shared long) y = x.load();
			assert(y.useCount == 2);

			assert(y.get == 123);
		}

	}

	//exchange
	nothrow @nogc unittest{

		//lvalue exchange
		{
			shared x = SharedPtr!(shared long).make(123);
			auto y = SharedPtr!(shared long).make(42);

			auto z = x.exchange(y);

			assert(x.load.get == 42);
			assert(y.get == 42);
			assert(z.get == 123);
		}

		//rvalue exchange
		{
			shared x = SharedPtr!(shared long).make(123);
			auto y = SharedPtr!(shared long).make(42);

			import core.lifetime : move;
			auto z = x.exchange(y.move);

			assert(x.load.get == 42);
			assert(y == null);
			assert(z.get == 123);
		}

		//null exchange (same as move)
		{
			shared x = SharedPtr!(shared long).make(123);

			auto z = x.exchange(null);

			assert(x.load == null);
			assert(z.get == 123);
		}

		//swap:
		{
			shared x = SharedPtr!(shared long).make(123);
			auto y = SharedPtr!(shared long).make(42);

			//opAssign is same as store
			import core.lifetime : move;
			y = x.exchange(y.move);

			assert(x.load.get == 42);
			assert(y.get == 123);
		}

	}

	//compareExchange
	nothrow @nogc unittest{
		alias Type = const long;
		static foreach(enum bool weak; [true, false]){
			//fail
			{
				SharedPtr!Type a = SharedPtr!Type.make(123);
				SharedPtr!Type b = SharedPtr!Type.make(42);
				SharedPtr!Type c = SharedPtr!Type.make(666);

				static if(weak)a.compareExchangeWeak(b, c);
				else a.compareExchangeStrong(b, c);

				assert(*a == 123);
				assert(*b == 123);
				assert(*c == 666);

			}

			//success
			{
				SharedPtr!Type a = SharedPtr!Type.make(123);
				SharedPtr!Type b = a;
				SharedPtr!Type c = SharedPtr!Type.make(666);

				static if(weak)a.compareExchangeWeak(b, c);
				else a.compareExchangeStrong(b, c);

				assert(*a == 666);
				assert(*b == 123);
				assert(*c == 666);
			}

			//shared fail
			{
				shared SharedPtr!(shared Type) a = SharedPtr!(shared Type).make(123);
				SharedPtr!(shared Type) b = SharedPtr!(shared Type).make(42);
				SharedPtr!(shared Type) c = SharedPtr!(shared Type).make(666);

				static if(weak)a.compareExchangeWeak(b, c);
				else a.compareExchangeStrong(b, c);

				auto tmp = a.exchange(null);
				assert(*tmp == 123);
				assert(*b == 123);
				assert(*c == 666);
			}

			//shared success
			{
				SharedPtr!(shared Type) b = SharedPtr!(shared Type).make(123);
				shared SharedPtr!(shared Type) a = b;
				SharedPtr!(shared Type) c = SharedPtr!(shared Type).make(666);

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
			SharedPtr!long x = SharedPtr!long.make(123);

			auto w = x.weak;    //weak ptr

			SharedPtr!long y = w.lock;

			assert(x == y);
			assert(x.useCount == 2);
			assert(y.get == 123);
		}

		{
			SharedPtr!long x = SharedPtr!long.make(123);

			auto w = x.weak;    //weak ptr

			assert(w.expired == false);

			x = SharedPtr!long.make(321);

			assert(w.expired == true);

			SharedPtr!long y = w.lock;

			assert(y == null);
		}
		{
			shared SharedPtr!(shared long) x = SharedPtr!(shared long).make(123);

			shared SharedPtr!(shared long).WeakType w = x.load.weak;    //weak ptr

			assert(w.expired == false);

			x = SharedPtr!(shared long).make(321);

			assert(w.expired == true);

			SharedPtr!(shared long) y = w.load.lock;

			assert(y == null);
		}
	}

	//expired
	pure nothrow @nogc @safe unittest{
		{
			SharedPtr!long x = SharedPtr!long.make(123);

			auto wx = x.weak;   //weak pointer

			assert(wx.expired == false);

			x = null;

			assert(wx.expired == true);
		}
	}

	//make
	pure nothrow @nogc unittest{
		{
			SharedPtr!long a = SharedPtr!long.make();
			assert(a.get == 0);

			SharedPtr!(const long) b = SharedPtr!long.make(2);
			assert(b.get == 2);
		}

		{
			static struct Struct{
				int i = 7;

				this(int i)pure nothrow @safe @nogc{
					this.i = i;
				}
			}

			SharedPtr!Struct s1 = SharedPtr!Struct.make();
			assert(s1.get.i == 7);

			SharedPtr!Struct s2 = SharedPtr!Struct.make(123);
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

			SharedPtr!Interface x = SharedPtr!Class.make(3);
			//assert(x.dynTo!Class.get.i == 3);
		}


	}

	//make dynamic array
	pure nothrow @nogc unittest{
		{
			auto arr = SharedPtr!(long[]).make(6, -1);
			assert(arr.length == 6);
			assert(arr.get.length == 6);

			import std.algorithm : all;
			assert(arr.get.all!(x => x == -1));

			for(long i = 0; i < 6; ++i)
				arr.get[i] = i;

			assert(arr.get == [0, 1, 2, 3, 4, 5]);
		}

		{
			static struct Struct{
				int i;
				double d;
			}

			{
				auto a = SharedPtr!(Struct[]).make(6, 42, 3.14);
				assert(a.length == 6);
				assert(a.get.length == 6);

				import std.algorithm : all;
				assert(a.get[].all!(x => (x.i == 42 && x.d == 3.14)));
			}

			{
				auto a = SharedPtr!(Struct[]).make(6);
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
				auto a = SharedPtr!(Class[]).make(6, null);
				assert(a.length == 6);

				import std.algorithm : all;
				assert(a.get[].all!(x => x is null));
			}

			{
				auto a = SharedPtr!(Class[]).make(6);
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
			SharedPtr!(long[6]) a = SharedPtr!(long[6]).make();
			assert(a.get.length == 6);
			assert(a.get[].all!(x => x == long.init));
		}
		{
			SharedPtr!(long[6]) a = SharedPtr!(long[6]).make(-1);
			assert(a.get.length == 6);
			assert(a.get[].all!(x => x == -1));
		}
		{
			long[6] tmp = [1, 2, 3, 4, 5, 6];

			SharedPtr!(const(long)[6]) a = SharedPtr!(long[6]).make(tmp);
			assert(a.get.length == 6);
			assert(a.get[]== tmp);
		}
		{
			static struct Struct{
				int i;
				double d;
			}

			auto a = SharedPtr!(Struct[6]).make(42, 3.14);
			assert(a.get.length == 6);

			import std.algorithm : all;
			assert(a.get[].all!(x => (x.i == 42 && x.d == 3.14)));


		}
	}

	//make deleter
	pure nothrow unittest{
		{
			long deleted = -1;
			long tmp = 123;
			auto x = SharedPtr!long.make(&tmp, (long* data){
				deleted = *data;
			});
			assert(deleted == -1);
			assert(*x == 123);

			x = null;
			assert(deleted == 123);
		}
	}

	//alloc
	pure nothrow @nogc unittest{
		{
			TestAllocator allocator;

			{
				SharedPtr!long a = SharedPtr!long.alloc(&allocator);
				assert(a.get == 0);

				SharedPtr!(const long) b = SharedPtr!long.alloc(&allocator, 2);
				assert(b.get == 2);
			}

			{
				static struct Struct{
					int i = 7;

					this(int i)pure nothrow @safe @nogc{
						this.i = i;
					}
				}

				SharedPtr!Struct s1 = SharedPtr!Struct.alloc(allocator);
				assert(s1.get.i == 7);

				SharedPtr!Struct s2 = SharedPtr!Struct.alloc(allocator, 123);
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


				SharedPtr!Interface x = SharedPtr!Class.alloc(&allocator, 3);
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
				auto x = SharedPtr!long.alloc(a);
				assert(x.get == 0);

				auto y = SharedPtr!(const long).alloc(a, 2);
				assert(y.get == 2);
			}

			{
				static struct Struct{
					int i = 7;

					this(int i)pure nothrow @safe @nogc{
						this.i = i;
					}
				}

				auto s1 = SharedPtr!Struct.alloc(a);
				assert(s1.get.i == 7);

				auto s2 = SharedPtr!Struct.alloc(a, 123);
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

				SharedPtr!(Interface, DestructorAllocatorType!(typeof(a))) x = SharedPtr!Class.alloc(a, 3);
				//assert(x.dynTo!Class.get.i == 3);
			}

		}
	}

	//alloc array
	nothrow unittest{
		{
			import std.experimental.allocator : allocatorObject;

			auto a = allocatorObject(Mallocator.instance);
			auto arr = SharedPtr!(long[], DestructorAllocatorType!(typeof(a))).alloc(a, 6, -1);
			assert(arr.length == 6);
			assert(arr.get.length == 6);

			import std.algorithm : all;
			assert(arr.get.all!(x => x == -1));

			for(long i = 0; i < 6; ++i)
				arr.get[i] = i;

			assert(arr.get == [0, 1, 2, 3, 4, 5]);
		}
	}

	//alloc deleter
	nothrow unittest{
		import std.experimental.allocator : make, dispose, allocatorObject;

		auto a = allocatorObject(Mallocator.instance);

		long deleted = -1;

		void del(long* data){
			deleted = *data;
			a.dispose(data);
		}

		auto x = SharedPtr!long.alloc(a, a.make!long(123), &del);
		assert(deleted == -1);
		assert(*x == 123);

		x = null;
		assert(deleted == 123);
	}

	//ctor
	pure nothrow @nogc @safe unittest{

		{
			SharedPtr!long x = SharedPtr!long.make(123);
			assert(x.useCount == 1);

			SharedPtr!long a = x;         //lvalue copy ctor
			assert(a == x);

			const SharedPtr!long b = x;   //lvalue copy ctor
			assert(b == x);

			SharedPtr!(const long) c = x; //lvalue ctor
			assert(c == x);

			//const SharedPtr!long d = b;   //lvalue ctor
			//assert(d == x);

			assert(x.useCount == 4);
		}

		{
			import core.lifetime : move;
			SharedPtr!long x = SharedPtr!long.make(123);
			assert(x.useCount == 1);

			SharedPtr!long a = move(x);        //rvalue copy ctor
			assert(a.useCount == 1);

			const SharedPtr!long b = move(a);  //rvalue copy ctor
			assert(b.useCount == 1);

			/+SharedPtr!(const long) c = b.load;  //rvalue ctor
			assert(c.useCount == 2);+/

			/+const SharedPtr!long d = move(c);  //rvalue ctor
			assert(d.useCount == 2);+/
		}

		/+{
			import core.lifetime : move;
			auto u = UniquePtr!(long, SharedControlBlock).make(123);

			SharedPtr!long s = move(u);        //rvalue copy ctor
			assert(s != null);
			assert(s.useCount == 1);

			SharedPtr!long s2 = UniquePtr!(long, SharedControlBlock).init;
			assert(s2 == null);

		}+/

		{
			import btl.autoptr.rc_ptr;

			import core.lifetime : move;
			auto rc = RcPtr!(long).make(123);
			assert(rc.useCount == 1);

			SharedPtr!long s = rc;
			assert(s != null);
			assert(s.useCount == 2);
			assert(rc.useCount == 2);

			SharedPtr!long s2 = RcPtr!(long).init;
			assert(s2 == null);
		}

	}

	//weak
	pure nothrow @nogc unittest{
		SharedPtr!long x = SharedPtr!long.make(123);
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

		SharedPtr!long x = SharedPtr!long.make(123);
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
		SharedPtr!long x = SharedPtr!long.make(123);
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
			SharedPtr!long x = SharedPtr!long.make(123);
			assert(*x.element == 123);

			x.get = 321;
			assert(*x.element == 321);

			const y = x;
			assert(*y.element == 321);
			assert(*x.element == 321);

			static assert(is(typeof(y.element) == const(long)*));
		}

		{
			auto s = SharedPtr!long.make(42);
			const w = s.weak;

			assert(*w.element == 42);

			s = null;
			assert(w.element is null);
		}

		{
			auto s = SharedPtr!long.make(42);
			auto w = s.weak;

			scope const p = w.element;

			s = null;
			assert(w.element is null);

			assert(p !is null); //p is dangling pointer!
		}
	}

	//opCast bool
	/+TODO
	@safe pure nothrow @nogc unittest{
		SharedPtr!long x = SharedPtr!long.make(123);
		assert(cast(bool)x);    //explicit cast
		assert(x);              //implicit cast
		x = null;
		assert(!cast(bool)x);   //explicit cast
		assert(!x);             //implicit cast
	}
	+/

	//opCast SharedPtr
	/+TODO
	@safe pure nothrow @nogc unittest{
		SharedPtr!long x = SharedPtr!long.make(123);
		auto y = cast(SharedPtr!(const long))x;
		auto z = cast(const SharedPtr!long)x;
		auto u = cast(const SharedPtr!(const long))x;
		assert(x.useCount == 4);
	}
	+/

	//opEquals SharedPtr
	pure @safe nothrow @nogc unittest{
		{
			SharedPtr!long x = SharedPtr!long.make(0);
			assert(x != null);
			x = null;
			assert(x == null);
		}

		{
			SharedPtr!long x = SharedPtr!long.make(123);
			SharedPtr!long y = SharedPtr!long.make(123);
			assert(x == x);
			assert(y == y);
			assert(x != y);
		}

		{
			SharedPtr!long x;
			SharedPtr!(const long) y;
			assert(x == x);
			assert(y == y);
			assert(x == y);
		}
	}

	//opEquals SharedPtr
	pure nothrow @nogc unittest{
		{
			SharedPtr!long x = SharedPtr!long.make(123);
			SharedPtr!long y = SharedPtr!long.make(123);
			assert(x == x.element);
			assert(y.element == y);
			assert(x != y.element);
		}
	}

	//opCmp
	pure nothrow @safe @nogc unittest{
		{
			const a = SharedPtr!long.make(42);
			const b = SharedPtr!long.make(123);
			const n = SharedPtr!long.init;

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
			const a = SharedPtr!long.make(42);
			const b = SharedPtr!long.make(123);

			assert(a <= a.element);
			assert(a.element >= a);

			assert((a < b.element) == !(a.element >= b));
			assert((a > b.element) == !(a.element <= b));
		}
	}

	//toHash
	pure nothrow @safe @nogc unittest{
		{
			SharedPtr!long x = SharedPtr!long.make(123);
			SharedPtr!long y = SharedPtr!long.make(123);
			assert(x.toHash == x.toHash);
			assert(y.toHash == y.toHash);
			assert(x.toHash != y.toHash);
			SharedPtr!(const long) z = x;
			assert(x.toHash == z.toHash);
		}
		{
			SharedPtr!long x;
			SharedPtr!(const long) y;
			assert(x.toHash == x.toHash);
			assert(y.toHash == y.toHash);
			assert(x.toHash == y.toHash);
		}
	}

	//proxySwap
	pure nothrow @nogc unittest{
		{
			SharedPtr!long a = SharedPtr!long.make(1);
			SharedPtr!long b = SharedPtr!long.make(2);
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
		auto x = SharedPtr!(int[]).make(10, -1);
		assert(x.length == 10);
		assert(x.get.length == 10);

		import std.algorithm : all;
		assert(x.get.all!(i => i == -1));
	}

}

pure nothrow @safe @nogc unittest{
	SharedPtr!void u = SharedPtr!void.make();
}


//test strong ptr -> weak ptr move ctor
unittest{
	{
		import core.lifetime : move;

		auto a = SharedPtr!int.make(1);
		auto b = a;
		assert(a.useCount == 2);
		assert(a.weakCount == 0);

		SharedPtr!int.WeakType x = move(a);
		assert(b.useCount == 1);
		assert(b.weakCount == 1);
	}
}

//test strong ptr -> weak ptr assign
unittest{
	{
		import core.lifetime : move;

		auto a = SharedPtr!int.make(1);
		auto b = SharedPtr!int.make(2);

		{
			SharedPtr!int.WeakType x = SharedPtr!int(a);
			assert(a.useCount == 1);
			assert(a.weakCount == 1);

			x = SharedPtr!int(b);
			assert(a.useCount == 1);
			assert(a.weakCount == 0);

			assert(b.useCount == 1);
			assert(b.weakCount == 1);
		}
		{
			SharedPtr!int.WeakType x = a;
			assert(a.useCount == 1);
			assert(a.weakCount == 1);

			SharedPtr!int.WeakType y = b;
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
	auto a = SharedPtr!int.make(1);
	auto b = a.weak;
	assert(a == b);
}

//self opAssign
unittest{
	auto a = SharedPtr!long.make(1);
	a = a;
}



//@safe const get:
@safe pure nothrow @nogc unittest{
	{
		const x = SharedPtr!long.make(42);
		assert(x.get == 42);
	}

	{
		const x = SharedPtr!void.make();
		x.get;
	}
}



@safe pure nothrow @nogc unittest{
	{
		auto p = SharedPtr!long.make(42);

		apply!((scope long* a, scope long* b){
			assert(p.useCount == 3);
			assert(a !is null);
			assert(b !is null);

			assert(a is b);
			assert(*a == 42);
		})(p, p);

	}

	{
		auto p = SharedPtr!long.make(42);

		apply!((scope long* a, scope long* b){
			assert(p.useCount == 3);
			assert(a !is null);
			assert(b !is null);

			assert(a is b);
			assert(*a == 42);
		})(p, p.weak());
	}

	{
		auto p = SharedPtr!long.make(42);
		auto w = SharedPtr!long.make(123).weak();
		assert(w.expired);

		apply!((scope long* a, scope long* b){
			assert(p.useCount == 2);
			assert(a !is null);
			assert(b is null);

			assert(*a == 42);
		})(p, w);
	}

}
