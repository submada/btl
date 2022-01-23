/**
	Mutable @nogc @safe string struct using `std.experimental.allocator` for allocations.

	License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
	Authors:   $(HTTP github.com/submada/btl.string, Adam Búš)
*/
module btl.string;



import std.traits : Unqual, Unconst, isSomeChar, isSomeString;
import std.meta : AliasSeq;

import btl.internal.mallocator;
import btl.internal.traits;
import btl.internal.forward;

import btl.string.encoding;
import btl.string.core;




/**
	Type used in forward constructors.
*/
alias Forward = btl.internal.forward.Forward;



/**
	True if `T` is a `BasicString` or implicitly converts to one, otherwise false.
*/
template isBasicString(T){
	import std.traits : isInstanceOf;

	enum bool isBasicString = isInstanceOf!(BasicString, T);
}



/**
	Standard utf-8 string type (alias to `BasicString!char`).
*/
alias String = BasicString!char;




/**
	The `BasicString` is the generalization of struct string for character of type `char`, `wchar` or `dchar`.

	`BasicString` use utf-8, utf-16 or utf-32 encoding.

	`BasicString` use SSO (Small String Optimization).

	Template parameters:

		`_Char` Character type. (`char`, `wchar` or `dchar`).

		`_Allocator` Type of the allocator object used to define the storage allocation model. By default Mallocator is used.

		`_Padding` Additional size of struct `BasicString`, increase max length of small string.

*/
template BasicString(
	_Char,
	_Allocator = Mallocator,
	size_t _Padding = 0,
)
if(isSomeChar!_Char && is(Unqual!_Char == _Char)){
	import std.experimental.allocator.common :  stateSize;
	import std.range : isInputRange, ElementEncodingType, isRandomAccessRange;
	import std.traits : Unqual, isIntegral, hasMember, isArray, isSafe;
	import core.lifetime: forward, move;


	alias Core = BasicStringCore!(_Char, _Allocator, _Padding);

	struct BasicString{

		/**
			True if allocator doesn't have state.
		*/
		public alias hasStatelessAllocator = Core.hasStatelessAllocator;



		/**
			Character type. (`char`, `wchar` or  `dchar`).
		*/
		public alias CharType = Core.CharType;



		/**
			Type of the allocator object used to define the storage allocation model. By default Mallocator is used.
		*/
		public alias AllocatorType = Core.AllocatorType;



		/**
			Maximal capacity of string, in terms of number of characters (utf code units).
		*/
		public alias maximalCapacity = Core.maximalCapacity;



		/**
			Minimal capacity of string (same as maximum capacity of small string), in terms of number of characters (utf code units).

			Examples:
				--------------------
				BasicString!char str;
				assert(str.empty);
				assert(str.capacity == BasicString!char.minimalCapacity);
				assert(str.capacity > 0);
				--------------------
		*/
		public alias minimalCapacity = Core.minimalCapacity;



		/**
			Returns allocator.
		*/
		static if(hasStatelessAllocator)
			public alias allocator = Core.allocator;
		else
			public @property auto allocator()inout{
				return this.core.allocator;
			}



		/**
			Returns whether the string is empty (i.e. whether its length is 0).

			Examples:
				--------------------
				BasicString!char str;
				assert(str.empty);

				str = "123";
				assert(!str.empty);
				--------------------
		*/
		public @property bool empty()const scope pure nothrow @safe @nogc{
			return (this.length == 0);
		}



		/**
			Returns the length of the string, in terms of number of characters (utf code units).

			This is the number of actual characters that conform the contents of the `BasicString`, which is not necessarily equal to its storage capacity.

			Examples:
				--------------------
				BasicString!char str = "123";
				assert(str.length == 3);

				BasicString!wchar wstr = "123";
				assert(wstr.length == 3);

				BasicString!dchar dstr = "123";
				assert(dstr.length == 3);

				--------------------
		*/
		public @property size_t length()const scope pure nothrow @trusted @nogc{
			return this.core.length;
		}



		/**
			Returns the size of the storage space currently allocated for the `BasicString`, expressed in terms of characters (utf code units).

			This capacity is not necessarily equal to the string length. It can be equal or greater, with the extra space allowing the object to optimize its operations when new characters are added to the `BasicString`.

			Notice that this capacity does not suppose a limit on the length of the `BasicString`. When this capacity is exhausted and more is needed, it is automatically expanded by the object (reallocating it storage space).

			The capacity of a `BasicString` can be altered any time the object is modified, even if this modification implies a reduction in size.

			The capacity of a `BasicString` can be explicitly altered by calling member `reserve`.

			Examples:
				--------------------
				BasicString!char str;
				assert(str.capacity == BasicString!char.minimalCapacity);

				str.reserve(str.capacity + 1);
				assert(str.capacity > BasicString!char.minimalCapacity);
				--------------------
		*/
		public @property size_t capacity()const scope pure nothrow @trusted @nogc{
			return this.core.capacity;
		}



		/**
			Return pointer to the first element.

			The pointer  returned may be invalidated by further calls to other member functions that modify the object.

			Examples:
				--------------------
				BasicString!char str = "123";
				char* ptr = str.ptr;
				assert(ptr[0 .. 3] == "123");
				--------------------

		*/
		public @property inout(CharType)* ptr()inout return pure nothrow @system @nogc{
			return this.core.ptr;
		}



		/**
			Return `true` if string is small (Small String Optimization)
		*/
		public @property bool small()const scope pure nothrow @safe @nogc{
			return this.core.small;
		}



		/**
			Return `true` if string is valid utf string.
		*/
		public @property bool valid()const scope pure nothrow @safe @nogc{
			return validate(this.core.chars);
		}



		/**
			Returns first utf code point(`dchar`) of the `BasicString`.

			This function shall not be called on empty strings.

			Examples:
				--------------------
				BasicString!char str = "á123";

				assert(str.frontCodePoint == 'á');
				--------------------
		*/
		public @property dchar frontCodePoint()const scope pure nothrow @trusted @nogc{
			auto chars = this.core.allChars;
			return decode(chars);
		}



		/**
			Returns the first character(utf8: `char`, utf16: `wchar`, utf32: `dchar`) of the `BasicString`.

			This function shall not be called on empty strings.

			Examples:
				--------------------
				{
					BasicString!char str = "123";

					assert(str.frontCodeUnit == '1');
				}

				{
					BasicString!char str = "á23";

					immutable(char)[2] a = "á";
					assert(str.frontCodeUnit == a[0]);
				}

				{
					BasicString!char str = "123";

					str.frontCodeUnit = 'x';

					assert(str == "x23");
				}
				--------------------
		*/
		public @property CharType frontCodeUnit()const scope pure nothrow @trusted @nogc{
			return *this.ptr;
		}

		/// ditto
		public @property CharType frontCodeUnit(const CharType val)scope pure nothrow @trusted @nogc{
			return *this.ptr = val;
		}



		/**
			Returns last utf code point(`dchar`) of the `BasicString`.

			This function shall not be called on empty strings.

			Examples:
				--------------------
				{
					BasicString!char str = "123á";

					assert(str.backCodePoint == 'á');
				}

				{
					BasicString!char str = "123á";
					str.backCodePoint = '4';
					assert(str == "1234");
				}
				--------------------
		*/
		public @property dchar backCodePoint()const scope pure nothrow @trusted @nogc{

			static if(is(CharType == dchar)){
				return this.backCodeUnit();
			}
			else{
				auto chars = this.core.chars;

				if(chars.length == 0)
					return dchar.init;

				const ubyte len = strideBack(chars);
				if(len == 0)
					return dchar.init;

				chars = chars[$ - len .. $];
				return decode(chars);
			}
		}

		/// ditto
		public @property dchar backCodePoint()(const dchar val)scope{

			static if(is(CharType == dchar)){
				return this.backCodeUnit(val);
			}
			else{
				auto chars = this.core.chars;

				if(chars.length == 0)
					return dchar.init;

				const ubyte len = strideBack(chars);
				if(len == 0)
					return dchar.init;

				this.core.length = (chars.length - len);
				this.append(val);
				return val;
			}
		}


		/**
			Returns the last character(utf8: `char`, utf16: `wchar`, utf32: `dchar`) of the `BasicString`.

			This function shall not be called on empty strings.

			Examples:
				--------------------
				{
					BasicString!char str = "123";

					assert(str.backCodeUnit == '3');
				}

				{
					BasicString!char str = "12á";

					immutable(char)[2] a = "á";
					assert(str.backCodeUnit == a[1]);
				}

				{
					BasicString!char str = "123";

					str.backCodeUnit = 'x';
					assert(str == "12x");
				}
				--------------------
		*/
		public @property CharType backCodeUnit()const scope pure nothrow @trusted @nogc{
			auto chars = this.core.chars;

			return (chars.length == 0)
				? CharType.init
				: chars[$ - 1];
		}

		/// ditto
		public @property CharType backCodeUnit(const CharType val)scope pure nothrow @trusted @nogc{
			auto chars = this.core.chars;

			return (chars.length == 0)
				? CharType.init
				: (chars[$ - 1] = val);
		}



		/**
			Erases the last utf code point of the `BasicString`, effectively reducing its length by code point length.

			Return number of erased characters, 0 if string is empty or if last character is not valid code point.

			Examples:
				--------------------
				{
					BasicString!char str = "á1";    //'á' is encoded as 2 chars

					assert(str.popBackCodePoint == 1);
					assert(str == "á");

					assert(str.popBackCodePoint == 2);
					assert(str.empty);

					assert(str.popBackCodePoint == 0);
					assert(str.empty);
				}

				{
					BasicString!char str = "1á";    //'á' is encoded as 2 chars
					assert(str.length == 3);

					str.erase(str.length - 1);
					assert(str.length == 2);

					assert(str.popBackCodePoint == 0);   //popBackCodePoint cannot remove invalid code points
					assert(str.length == 2);
				}
				--------------------
		*/
		public ubyte popBackCodePoint()scope pure nothrow @trusted @nogc{
			if(this.empty)
				return 0;

			const ubyte n = strideBack(this.core.chars);

			this.core.length = (this.length - n);

			return n;
		}



		/**
			Erases the last code unit of the `BasicString`, effectively reducing its length by 1.

			Return number of erased characters, `false` if string is empty or `true` if is not.

			Examples:
				--------------------
				BasicString!char str = "á1";    //'á' is encoded as 2 chars
				assert(str.length == 3);

				assert(str.popBackCodeUnit);
				assert(str.length == 2);

				assert(str.popBackCodeUnit);
				assert(str.length == 1);

				assert(str.popBackCodeUnit);
				assert(str.empty);

				assert(!str.popBackCodeUnit);
				assert(str.empty);
				--------------------
		*/
		public bool popBackCodeUnit()scope pure nothrow @trusted @nogc{
			if(this.empty)
				return false;

			this.core.length = (this.length - 1);

			return true;
		}



		/**
			Erases the contents of the `BasicString`, which becomes an empty string (with a length of 0 characters).

			Doesn't change capacity of string.

			Examples:
				--------------------
				BasicString!char str = "123";

				str.reserve(str.capacity * 2);
				assert(str.length == 3);

				const size_t cap = str.capacity;
				str.clear();
				assert(str.capacity == cap);
				--------------------
		*/
		public void clear()scope pure nothrow @trusted @nogc{
			this.core.length = 0;
		}



		/**
			Erases and deallocate the contents of the `BasicString`, which becomes an empty string (with a length of 0 characters).

			Examples:
				--------------------
				BasicString!char str = "123";

				str.reserve(str.capacity * 2);
				assert(str.length == 3);

				const size_t cap = str.capacity;
				str.clear();
				assert(str.capacity == cap);

				str.release();
				assert(str.capacity < cap);
				assert(str.capacity == BasicString!char.minimalCapacity);
				--------------------
		*/
		public void release()scope{
			this.core.release();
		}



		/**
			Requests that the string capacity be adapted to a planned change in size to a length of up to n characters (utf code units).

			If n is greater than the current string capacity, the function causes the container to increase its capacity to n characters (or greater).

			In all other cases, it do nothing.

			This function has no effect on the string length and cannot alter its content.

			Examples:
				--------------------
				BasicString!char str = "123";
				assert(str.capacity == BasicString!char.minimalCapacity);

				const size_t cap = (str.capacity * 2);
				str.reserve(cap);
				assert(str.capacity > BasicString!char.minimalCapacity);
				assert(str.capacity >= cap);
				--------------------
		*/
		public size_t reserve(const size_t n)scope{
			return this.core.reserve(n);
		}



		/**
			Resizes the string to a length of `n` characters (utf code units).

			If `n` is smaller than the current string length, the current value is shortened to its first `n` character, removing the characters beyond the nth.

			If `n` is greater than the current string length, the current content is extended by inserting at the end as many characters as needed to reach a size of n.

			If `ch` is specified, the new elements are initialized as copies of `ch`, otherwise, they are `_`.

			Examples:
				--------------------
				BasicString!char str = "123";

				str.resize(5, 'x');
				assert(str == "123xx");

				str.resize(2);
				assert(str == "12");
				--------------------
		*/
		public void resize(const size_t n, const CharType ch = '_')scope{
			const size_t old_length = this.length;

			if(old_length > n){
				this.core.length = n;
			}
			else if(old_length < n){
				this.append(ch, n - old_length);
			}
		}



		/**
			Requests the `BasicString` to reduce its capacity to fit its length.

			The request is non-binding.

			This function has no effect on the string length and cannot alter its content.

			Returns new capacity.

			Examples:
				--------------------
				BasicString!char str = "123";
				assert(str.capacity == BasicString!char.minimalCapacity);

				str.reserve(str.capacity * 2);
				assert(str.capacity > BasicString!char.minimalCapacity);

				str.shrinkToFit();
				assert(str.capacity == BasicString!char.minimalCapacity);
				--------------------
		*/
		public size_t shrinkToFit()scope{
			return this.core.shrinkToFit();
		}



		/**
			Destroys the `BasicString` object.

			This deallocates all the storage capacity allocated by the `BasicString` using its allocator.
		*/
		public ~this()scope{
		}



		/**
			Constructs a empty `BasicString` object.

			Examples:
				--------------------
				{
					BasicString!char str = null;
					assert(str.empty);
				}
				--------------------
		*/
		public this(typeof(null) nil)scope pure nothrow @safe @nogc{
		}



		/**
			Constructs a empty `BasicString` object with `allocator`.

			Parameters:
				`allocator` allocator parameter.

			Examples:
				--------------------
				{
					BasicString!(char, Mallocator) str = Mallocator.init;
					assert(str.empty);
				}
				--------------------
		*/
		public this(AllocatorType allocator)scope {
			this.core = Core(forward!allocator);
		}



		/**
			Constructs a `BasicString` object, initializing its value to char value `character`.

			Parameters:
				`character` can by type char|wchar|dchar.

			Examples:
				--------------------
				{
					BasicString!char str = 'x';
					assert(str == "x");
				}

				{
					BasicString!char str = '読';
					assert(str == "読");
				}
				--------------------
		*/
		public this(C)(const C character)scope
		if(isSomeChar!C){
			this.core.ctor(character);
		}



		/**
			Constructs a `BasicString` object, initializing its value to char value `character`.

			Parameters:
				`character` can by type char|wchar|dchar.

				`allocator` allocator parameter.

			Examples:
				--------------------
				{
					auto str = BasicString!(char, Mallocator)('読', Mallocator.init);
					assert(str == "読");
				}
				--------------------
		*/
		public this(C)(const C character, AllocatorType allocator)scope
		if(isSomeChar!C){
			this.core = Core(forward!allocator);
			this.core.ctor(character);
		}



		/**
			Constructs a `BasicString` object from char slice `slice`.

			Parameters:
				`slice` is slice of characters (`const char[]`, `const wchar[]`, `const dchar[]`).

			Examples:
				--------------------
				{
					BasicString!char str = "test";
					assert(str == "test");
				}

				{
					BasicString!char str = "test 読"d;
					assert(str == "test 読");
				}

				{
					wchar[3] data = [cast(wchar)'1', '2', '3'];
					BasicString!char str = data[];
					assert(str == "123");
				}
				--------------------
		*/
		public this(this This)(scope const CharType[] slice)scope{
			this.core.ctor(slice);
		}

		/// ditto
		public this(this This, C)(scope const C[] slice)scope
		if(isSomeChar!C && !is(immutable C == immutable CharType)){
			this.core.ctor(slice);
		}



		/**
			Constructs a `BasicString` object from char slice `slice`.

			Parameters:
				`slice` is slice of characters (`const char[]`, `const wchar[]`, `const dchar[]`).

				`allocator` allocator parameter.

			Examples:
				--------------------
				{
					auto str = BasicString!(char, Mallocator)("test", Mallocator.init);
					assert(str == "test");
				}

				{
					auto str = BasicString!(char, Mallocator)("test 読"d, Mallocator.init);
					assert(str == "test 読");
				}

				{

					wchar[3] data = [cast(wchar)'1', '2', '3'];
					auto str = BasicString!(char, Mallocator)(data[], Mallocator.init);
					assert(str == "123");
				}
				--------------------
		*/
		public this(this This)(scope const CharType[] slice, AllocatorType allocator)scope{
			this.core = Core(forward!allocator);
			this.core.ctor(slice);
		}

		/// ditto
		public this(this This, C)(scope const C[] slice, AllocatorType allocator)scope
		if(isSomeChar!C && !is(immutable C == immutable CharType)){
			this.core = Core(forward!allocator);
			this.core.ctor(slice);
		}



		/**
			Constructs a `BasicString` object, initializing its value from integer `integer`.

			Parameters:

				`integer` integers value.

			Examples:
				--------------------
				{
					BasicString!char str = 123uL;
					assert(str == "123");
				}

				{
					BasicString!dchar str = -123;
					assert(str == "-123");
				}
				--------------------
		*/
		public this(I)(I integer)scope
		if(isIntegral!I){
			this.core.ctor(integer);
		}



		/**
			Constructs a `BasicString` object, initializing its value from integer `integer`.

			Parameters:

				`integer` integers value.

				`allocator` allocator parameter.

			Examples:
				--------------------
				{
					auto str = BasicString!(char, Mallocator)(123uL, Mallocator.init);
					assert(str == "123");
				}

				{
					auto str = BasicString!(dchar, Mallocator)(-123, Mallocator.init);
					assert(str == "-123");
				}
				--------------------
		*/
		public this(I)(I integer, AllocatorType allocator)scope
		if(isIntegral!I){
			this.core = Core(forward!allocator);
			this.core.ctor(integer);
		}



		/**
			Constructs a `BasicString` object from other `BasicString` object.

			Parameters:

				`rhs` `BasicString` rvalue/lvalue

				`allocator` optional allocator parameter.

			Examples:
				--------------------
				{
					BasicString!char a = "123";
					BasicString!char b = a;
					assert(b == "123");
				}

				{
					BasicString!dchar a = "123";
					BasicString!char b = a;
					assert(b == "123");
				}

				{
					BasicString!dchar a = "123";
					auto b = BasicString!char(a, Mallocator.init);
					assert(b == "123");
				}

				import core.lifetime : move;
				{
					BasicString!char a = "123";
					BasicString!char b = move(a);
					assert(b == "123");
				}
				--------------------
		*/
		public this(this This, Rhs)(auto ref scope const Rhs rhs)scope
		if(    isBasicString!Rhs
			&& isConstructable!(rhs, This)
			&& (isRef!rhs || !is(immutable This == immutable Rhs))
		){
			this(forward!rhs, Forward.init);
		}

		/+public static auto opCall(Rhs)(scope Rhs rhs)scope
		if(    isBasicString!Rhs
			&& isMoveConstructable!(rhs, typeof(this))
			&& is(immutable This == immutable Rhs)
		){
			assert(0);
		}+/

		/// ditto
		public this(this This, Rhs)(auto ref scope const Rhs rhs, AllocatorType allocator)scope
		if(isBasicString!Rhs){
			this.core = Core(forward!allocator);
			this.core.ctor(rhs.core.chars);
		}

		/// ditto
		public this(this This, Rhs)(auto ref scope const Rhs rhs, Forward)scope
		if(isBasicString!Rhs && isConstructable!(rhs, This)){
			static if(isRef!rhs)
				this.core = Core(rhs.core, Forward.init);
			else
				this.core = Core(move(rhs.core), Forward.init);
		}




		/**
			Copy constructor if `AllocatorType` is statless.

			Parameter `rhs` is const.
		*/
		static if(hasStatelessAllocator)
		public this(ref scope const typeof(this) rhs)scope{
			this(rhs.core.chars);
		}



		/**
			Copy constructor if `AllocatorType` has state.

			Parameter `rhs` is mutable.
		*/
		static if(!hasStatelessAllocator)
		public this(ref scope typeof(this) rhs)scope{
			this(rhs.core.chars, rhs.allocator);
		}



		/**
			Assigns a new value `rhs` to the string, replacing its current contents.

			Parameter `rhs` can by type of `null`, `BasicString!(...)`, `char|wchar|dchar` array/slice/character or integer (integer is transformed to string).

			Return referece to `this`.

			Examples:
				--------------------
				BasicString!char str = "123";
				assert(!str.empty);

				str = null;
				assert(str.empty);

				str = 'X';
				assert(str == "X");

				str = "abc"w;
				assert(str == "abc");

				str = -123;
				assert(str == "-123");

				str = BasicString!char("42");
				assert(str == "42");

				str = BasicString!wchar("abc");
				assert(str == "abc");
				--------------------
		*/
		public ref typeof(this) opAssign(typeof(null) nil)scope pure nothrow @safe @nogc{
			this.clear();
			return this;
		}

		/// ditto
		public ref typeof(this) opAssign(scope const CharType[] slice)scope{
			this.clear();

			this.reserve(encodedLength!CharType(slice));
			this.core.length = slice.encodeTo(this.core.allChars);

			return this;
		}

		/// ditto
		public ref typeof(this) opAssign(C)(scope const C[] slice)scope
		if(isSomeChar!C){
			this.clear();

			this.reserve(encodedLength!CharType(slice));
			this.core.length = slice.encodeTo(this.core.allChars);

			return this;
		}

		/// ditto
		public ref typeof(this) opAssign(C)(const C character)scope
		if(isSomeChar!C){
			this.clear();

			assert(character.encodedLength!CharType <= minimalCapacity);
			this.core.length = character.encodeTo(this.core.allChars);

			return this;
		}

		/// ditto
		public ref typeof(this) opAssign(I)(const I integer)scope
		if(isIntegral!I){
			this.clear();

			assert(integer.encodedLength!CharType <= minimalCapacity);
			this.core.length = integer.encodeTo(this.core.allChars);

			return this;
		}

		/// ditto
		public ref typeof(this) opAssign(scope typeof(this) rhs)scope{
			this.proxySwap(rhs);
			return this;
		}

		/// ditto
		public ref typeof(this) opAssign(Rhs)(auto ref scope Rhs rhs)scope
		if(isBasicString!Rhs){
			return this.opAssign(rhs.core.chars);
		}



		/**
			Extends the `BasicString` by appending additional characters at the end of its current value.

			This is alias to `append`
		*/
		public template opOpAssign(string op)
		if(op == "+" || op == "~"){
			alias opOpAssign = append;
		}



		/**
			Returns a newly constructed `BasicString` object with its value being the concatenation of the characters in `this` followed by those of `rhs`.

			Parameter `rhs` can by type of `BasicString!(...)`, `char|wchar|dchar` array/slice/character.

			Examples:
				--------------------
				BasicString!char str = null;
				assert(str.empty);

				str = str + '1';
				assert(str == "1");

				str = str + "23"d;
				assert(str == "123");

				str = str + BasicString!dchar("456");
				assert(str == "123456");
				--------------------
		*/
		public typeof(this) opBinary(string op)(scope const CharType[] rhs)scope
		if(op == "+" || op == "~"){
			static if(hasStatelessAllocator)
				return this.build(this.core.chars, rhs);
			else
				return this.build(this.core.allocator, this.core.chars, rhs);
		}

		/// ditto
		public typeof(this) opBinary(string op, Rhs)(auto ref scope const Rhs rhs)scope
		if((op == "+" || op == "~")
			&& (isBasicString!Rhs || isSomeChar!Rhs || isSomeString!Rhs || isCharArray!Rhs || isIntegral!Rhs)
		){
			static if(hasStatelessAllocator)
				return this.build(this.core.chars, forward!rhs);
			else
				return this.build(this.core.allocator, this.core.chars, forward!rhs);
		}



		/**
			Returns a newly constructed `BasicString` object with its value being the concatenation of the characters in `lhs` followed by those of `this`.

			Parameter `lhs` can by type of `BasicString!(...)`, `char|wchar|dchar` array/slice/character.

			Examples:
				--------------------
				BasicString!char str = null;
				assert(str.empty);

				str = '1' + str;
				assert(str == "1");

				str = "32"d + str;
				assert(str == "321");

				str = BasicString!dchar("654") + str;
				assert(str == "654321");
				--------------------
		*/
		public typeof(this) opBinaryRight(string op)(scope const CharType[] lhs)scope
		if(op == "+" || op == "~"){
			static if(hasStatelessAllocator)
				return this.build(lhs, this.core.chars);
			else
				return this.build(this.core.allocator, lhs, this.core.chars);
		}

		/// ditto
		public typeof(this) opBinaryRight(string op, Lhs)(auto ref scope const Lhs lhs)scope
		if((op == "+" || op == "~")
			&& (isSomeChar!Lhs || isSomeString!Lhs || isCharArray!Lhs || isIntegral!Lhs)
		){
			static if(hasStatelessAllocator)
				return this.build(forward!lhs, this.core.chars);
			else
				return this.build(this.core.allocator, forward!lhs, this.core.chars);
		}



		/**
			Calculates the hash value of string.
		*/
		public size_t toHash()const pure nothrow @safe @nogc{
			return hashOf(this.core.chars);
		}



		/**
			Compares the contents of a string with another string, range, char/wchar/dchar or integer.

			Returns `true` if they are equal, `false` otherwise

			Examples:
				--------------------
				BasicString!char str = "123";

				assert(str == "123");
				assert("123" == str);

				assert(str == "123"w);
				assert("123"w == str);

				assert(str == "123"d);
				assert("123"d == str);

				assert(str == BasicString!wchar("123"));
				assert(BasicString!wchar("123") == str);

				assert(str == 123);
				assert(123 == str);

				import std.range : only;
				assert(str == only('1', '2', '3'));
				assert(only('1', '2', '3') == str);
				--------------------
		*/
		public bool opEquals(scope const CharType[] rhs)const scope pure nothrow @safe @nogc{
			return this.core.opEquals(rhs[]);
		}

		/// ditto
		public bool opEquals(Rhs)(auto ref scope Rhs rhs)const scope
		if(isBasicString!Rhs || isSomeChar!Rhs || isSomeString!Rhs || isCharArray!Rhs || isIntegral!Rhs || isInputCharRange!Rhs){

			static if(isBasicString!Rhs){
				return this.core.opEquals(rhs.core.chars);
			}
			else static if(isSomeString!Rhs || isCharArray!Rhs){
				return this.core.opEquals(rhs[]);
			}
			else static if(isSomeChar!Rhs){
				import std.range : only;
				return this.core.opEquals(only(rhs));
			}
			else static if(isIntegral!Rhs){
				import std.conv : toChars;
				return  this.core.opEquals(toChars(rhs + 0));
			}
			else static if(isInputRange!Rhs){
				return this.core.opEquals(rhs);
			}
			else{
				static assert(0, "invalid type '" ~ Rhs.stringof ~ "'");
			}
		}



		/**
			Compares the contents of a string with another string, range, char/wchar/dchar or integer.
		*/
		public int opCmp(scope const CharType[] rhs)const scope pure nothrow @safe @nogc{
			return this.core.opCmp(rhs[]);
		}

		/// ditto
		public int opCmp(Rhs)(auto ref scope Rhs rhs)const scope
		if(isBasicString!Rhs || isSomeChar!Rhs || isSomeString!Rhs || isCharArray!Rhs || isIntegral!Rhs || isInputCharRange!Rhs){

			static if(isBasicString!Val){
				return this.core.opCmp(rhs._chars);
			}
			else static if(isSomeString!Val || isCharArray!Val){
				return this.core.opCmp(rhs[]);
			}
			else static if(isSomeChar!Val){
				import std.range : only;
				return this.core.opCmp(only(rhs));
			}
			else static if(isIntegral!Val){
				import std.conv : toChars;
				return this.core.opCmp(toChars(rhs + 0));
			}
			else static if(isInputRange!Val){
				return this.core.opCmp(val);
			}
			else{
				static assert(0, "invalid type '" ~ Val.stringof ~ "'");
			}
		}



		/**
			Return slice of all character.

			The slice returned may be invalidated by further calls to other member functions that modify the object.

			Examples:
				--------------------
				BasicString!char str = "123";

				char[] slice = str[];
				assert(slice.length == str.length);
				assert(slice.ptr is str.ptr);

				str.reserve(str.capacity * 2);
				assert(slice.length == str.length);
				assert(slice.ptr !is str.ptr);  // slice contains dangling pointer.
				--------------------
		*/
		public inout(CharType)[] opIndex()inout return pure nothrow @system @nogc{
			return this.core.chars;
		}



		/**
			Returns character at specified location `pos`.

			Examples:
				--------------------
				BasicString!char str = "abcd";

				assert(str[1] == 'b');
				--------------------
		*/
		public CharType opIndex(const size_t pos)const scope pure nothrow @trusted @nogc{
			assert(0 <= pos && pos < this.length);

			return *(this.ptr + pos);
		}



		/**
			Returns a slice [begin .. end]. If the requested substring extends past the end of the string, the returned slice is [begin .. length()].

			The slice returned may be invalidated by further calls to other member functions that modify the object.

			Examples:
				--------------------
				BasicString!char str = "123456";

				assert(str[1 .. $-1] == "2345");
				--------------------
		*/
		public inout(CharType)[] opSlice(const size_t begin, const size_t end)inout return pure nothrow @system @nogc{
			const len = this.length;

			return this.ptr[min(len, begin) .. min(len, end)];
		}



		/**
			Assign character at specified location `pos` to value `val`.

			Returns 'val'.

			Examples:
				--------------------
				BasicString!char str = "abcd";

				str[1] = 'x';

				assert(str == "axcd");
				--------------------
		*/
		public CharType opIndexAssign(const CharType val, const size_t pos)scope pure nothrow @trusted @nogc{
			assert(0 <= pos && pos < this.length);

			return *(this.ptr + pos) = val;
		}



		/**
			Returns the length of the string, in terms of number of characters.

			Same as `length()`.
		*/
		public size_t opDollar()const scope pure nothrow @safe @nogc{
			return this.length;
		}



		/**
			Swaps the contents of `this` and `rhs`.

			Examples:
				--------------------
				BasicString!char a = "1";
				BasicString!char b = "2";

				a.proxySwap(b);
				assert(a == "2");
				assert(b == "1");

				import std.algorithm.mutation : swap;

				swap(a, b);
				assert(a == "1");
				assert(b == "2");
				--------------------
		*/
		public void proxySwap(ref scope typeof(this) rhs)scope pure nothrow @trusted @nogc{
			this.core.proxySwap(rhs.core);

		}



		/**
			Extends the `BasicString` by appending additional characters at the end of string.

			Return number of inserted characters.

			Parameters:
				`val` appended value.

				`count` Number of times `val` is appended.

			Examples:
				--------------------
				{
					BasicString!char str = "123456";

					str.append('x', 2);
					assert(str == "123456xx");
				}

				{
					BasicString!char str = "123456";

					str.append("abc");
					assert(str == "123456abc");
				}

				{
					BasicString!char str = "123456";
					BasicString!char str2 = "xyz";

					str.append(str2);
					assert(str == "123456xyz");
				}

				{
					BasicString!char str = "12";

					str.append(+34);
					assert(str == "1234");
				}
				--------------------
		*/
		public size_t append(const CharType[] val, const size_t count = 1)scope{
			return this.core.append(val, count);
		}

		/// ditto
		public size_t append(Val)(auto ref scope const Val val, const size_t count = 1)scope
		if(isBasicString!Val || isSomeChar!Val || isSomeString!Val || isCharArray!Val || isIntegral!Val){

			static if(isBasicString!Val){
				return this.core.append(val.core.chars, count);
			}
			else static if(isSomeString!Val || isCharArray!Val){
				return this.core.append(val[], count);
			}
			else static if(isSomeChar!Val || isIntegral!Val){
				return this.core.append(val, count);
			}
			else{
				static assert(0, "invalid type '" ~ Val.stringof ~ "'");
			}
		}



		/**
			Inserts additional characters into the `BasicString` right before the character indicated by `pos` or `ptr`.

			Return number of inserted characters.

			If parameters are out of range then there is no inserted value and in debug mode assert throw error.

			Parameters are out of range if `pos` is larger then `.length` or `ptr` is smaller then `this.ptr` or `ptr` point to address larger then `this.ptr + this.length`

			Parameters:
				`pos` Insertion point, the new contents are inserted before the character at position `pos`.

				`ptr` Pointer pointing to the insertion point, the new contents are inserted before the character pointed by ptr.

				`val` Value inserted before insertion point `pos` or `ptr`.

				`count` Number of times `val` is inserted.

			Examples:
				--------------------
				{
					BasicString!char str = "123456";

					str.insert(2, 'x', 2);
					assert(str == "12xx3456");
				}

				{
					BasicString!char str = "123456";

					str.insert(2, "abc");
					assert(str == "12abc3456");
				}

				{
					BasicString!char str = "123456";
					BasicString!char str2 = "abc";

					str.insert(2, str2);
					assert(str == "12abc3456");
				}

				{
					BasicString!char str = "123456";

					str.insert(str.ptr + 2, 'x', 2);
					assert(str == "12xx3456");
				}

				{
					BasicString!char str = "123456";

					str.insert(str.ptr + 2, "abc");
					assert(str == "12abc3456");
				}

				{
					BasicString!char str = "123456";
					BasicString!char str2 = "abc";

					str.insert(str.ptr + 2, str2);
					assert(str == "12abc3456");
				}
				--------------------

		*/
		public size_t insert(const size_t pos, const scope CharType[] val, const size_t count = 1)scope{
			return this.core.insert(pos, val, count);
		}

		/// ditto
		public size_t insert(Val)(const size_t pos, auto ref const scope Val val, const size_t count = 1)scope
		if(isBasicString!Val || isSomeChar!Val || isSomeString!Val || isIntegral!Val){

			static if(isBasicString!Val || isSomeString!Val){
				return this.core.insert(pos, val[], count);
			}
			else static if(isSomeChar!Val || isIntegral!Val){
				return this.core.insert(pos, val, count);
			}
			else{
				static assert(0, "invalid type '" ~ Val.stringof ~ "'");
			}
		}

		/// ditto
		public size_t insert(const CharType* ptr, const scope CharType[] val, const size_t count = 1)scope{
			const size_t pos = this._insert_ptr_to_pos(ptr);

			return this.core.insert(pos, val, count);
		}

		/// ditto
		public size_t insert(Val)(const CharType* ptr, auto ref const scope Val val, const size_t count = 1)scope
		if(isBasicString!Val || isSomeChar!Val || isSomeString!Val || isIntegral!Val){
			const size_t pos = this._insert_ptr_to_pos(ptr);

			static if(isBasicString!Val || isSomeString!Val){
				return this.core.insert(pos, val[], count);
			}
			else static if(isSomeChar!Val || isIntegral!Val){
				return this.core.insert(pos, val, count);
			}
			else{
				static assert(0, "invalid type '" ~ Val.stringof ~ "'");
			}
		}


		private size_t _insert_ptr_to_pos(const CharType* ptr)scope const pure nothrow @trusted @nogc{
			return (ptr > this.ptr)
				? (ptr - this.ptr)
				: 0;
		}



		/**
			Removes specified characters from the string.

			Parameters:
				`pos` position of first character to be removed.

				`n` number of character to be removed.

				`ptr` pointer to character to be removed.

				`slice` sub-slice to be removed, `slice` must be subset of `this`

			Examples:
				--------------------
				{
					BasicString!char str = "123456";

					str.erase(2);
					assert(str == "12");
				}

				{
					BasicString!char str = "123456";

					str.erase(1, 2);
					assert(str == "1456");
				}

				{
					BasicString!char str = "123456";

					str.erase(str.ptr + 2);
					assert(str == "12");
				}

				{
					BasicString!char str = "123456";

					str.erase(str[1 .. $-1]);
					assert(str == "16");
				}
				--------------------
		*/
		public void erase(const size_t pos)scope pure nothrow @trusted @nogc{
			this.core.length = min(this.length, pos);
		}

		/// ditto
		public void erase(const size_t pos, const size_t n)scope pure nothrow @trusted @nogc{
			const chars = this.core.chars;

			if(pos >= this.length)
				return;

			this.core.erase(pos, n);
		}

		/// ditto
		public void erase(scope const CharType* ptr)scope pure nothrow @trusted @nogc{
			const chars = this.core.chars;

			if(ptr <= chars.ptr)
				this.core.length = 0;
			else
				this.core.length = min(chars.length, ptr - chars.ptr);
		}

		/// ditto
		public void erase(scope const CharType[] slice)scope pure nothrow @trusted @nogc{
			const chars = this.core.chars;

			if(slice.ptr <= chars.ptr){
				const size_t offset = (chars.ptr - slice.ptr);

				if(slice.length <= offset)
					return;

				enum size_t pos = 0;
				const size_t len = (slice.length - offset);

				this.core.erase(pos, len);
			}
			else{
				const size_t offset = (slice.ptr - chars.ptr);

				if(chars.length <= offset)
					return;

				alias pos = offset;
				const size_t len = slice.length;

				this.core.erase(pos, len);

			}
		}


		/**
			Replaces the portion of the string that begins at character `pos` and spans `len` characters (or the part of the string in the slice `slice`) by new contents.

			Parameters:
				`pos` position of the first character to be replaced.

				`len` number of characters to replace (if the string is shorter, as many characters as possible are replaced).

				`slice` sub-slice to be removed, `slice` must be subset of `this`

				`val` inserted value.

				`count` number of times `val` is inserted.

			Examples:
				--------------------
				{
					BasicString!char str = "123456";

					str.replace(2, 2, 'x', 5);
					assert(str == "12xxxxx56");
				}

				{
					BasicString!char str = "123456";

					str.replace(2, 2, "abcdef");
					assert(str == "12abcdef56");
				}

				{
					BasicString!char str = "123456";
					BasicString!char str2 = "xy";

					str.replace(2, 3, str2);
					assert(str == "12xy56");
				}

				{
					BasicString!char str = "123456";

					str.replace(str[2 .. 4], 'x', 5);
					assert(str == "12xxxxx56");
				}

				{
					BasicString!char str = "123456";

					str.replace(str[2 .. 4], "abcdef");
					assert(str == "12abcdef56");
				}

				{
					BasicString!char str = "123456";
					BasicString!char str2 = "xy";

					str.replace(str[2 .. $], str2);
					assert(str == "12xy56");
				}
				--------------------
		*/
		public ref typeof(this) replace(const size_t pos, const size_t len, scope const CharType[] val, const size_t count = 1)return scope{
			this.core.replace(pos, len, val, count);
			return this;
		}

		/// ditto
		public ref typeof(this) replace(Val)(const size_t pos, const size_t len, auto ref scope const Val val, const size_t count = 1)return scope
		if(isBasicString!Val || isSomeChar!Val || isSomeString!Val || isIntegral!Val || isCharArray!Val){

			static if(isBasicString!Val || isSomeString!Val || isCharArray!Val){
				this.core.replace(pos, len, val[], count);
			}
			else static if(isSomeChar!Val || isIntegral!Val){
				this.core.replace(pos, len, val, count);
			}
			else{
				static assert(0, "invalid type '" ~ Val.stringof ~ "'");
			}

			return this;
		}

		/// ditto
		public ref typeof(this) replace(scope const CharType[] slice, scope const CharType[] val, const size_t count = 1)return scope{
			this.core.replace(slice, val, count);
			return this;
		}

		/// ditto
		public ref typeof(this) replace(Val)(scope const CharType[] slice, auto ref scope const Val val, const size_t count = 1)return scope
		if(isBasicString!Val || isSomeChar!Val || isSomeString!Val || isIntegral!Val || isCharArray!Val){

			static if(isBasicString!Val || isSomeString!Val || isCharArray!Val){
				this.core.replace(slice, val[], count);
			}
			else static if(isSomeChar!Val || isIntegral!Val){
				this.core.replace(slice, val, count);
			}
			else{
				static assert(0, "invalid type '" ~ Val.stringof ~ "'");
			}

			return this;
		}



		///Alias to append.
		public alias put = append;

		///Alias to `popBackCodeUnit`.
		public alias popBack = popBackCodeUnit;

		///Alias to `frontCodeUnit`.
		public alias front = frontCodeUnit;

		///Alias to `backCodeUnit`.
		public alias back = backCodeUnit;


		/**
			Static function which return `BasicString` construct from arguments `args`.

			Parameters:
				`allocator` exists only if template parameter `_Allocator` has state.

				`args` values of type `char|wchar|dchar` array/slice/character or `BasicString`.

			Examples:
				--------------------
				BasicString!char str = BasicString!char.build('1', cast(dchar)'2', "345"d, BasicString!wchar("678"));

				assert(str == "12345678");
				--------------------
		*/
		public static typeof(this) build(Args...)(auto ref scope const Args args)
		if(Args.length > 0 && !is(immutable Args[0] == immutable AllocatorType)){
			import core.lifetime : forward;

			auto result = BasicString.init;

			result._build_impl(forward!args);

			return move(result);
		}

		/// ditto
		public static typeof(this) build(Args...)(AllocatorType allocator, auto ref scope const Args args){
			import core.lifetime : forward;

			auto result = BasicString(forward!allocator);

			result._build_impl(forward!args);

			return move(result);
		}

		private void _build_impl(Args...)(auto ref scope const Args args)scope{
			import std.traits : isArray;

			assert(this.empty);
			//this.clear();
			size_t new_length = 0;

			static foreach(enum I, alias Arg; Args){
				static if(isBasicString!Arg)
					new_length += encodedLength!CharType(args[I].core.chars);
				else static if(isArray!Arg &&  isSomeChar!(ElementEncodingType!Arg))
					new_length += encodedLength!CharType(args[I][]);
				else static if(isSomeChar!Arg)
					new_length += encodedLength!CharType(args[I]);
				else static assert(0, "wrong type '" ~ typeof(args[I]).stringof ~ "'");
			}

			if(new_length == 0)
				return;


			alias result = this;

			result.reserve(new_length);

			CharType[] data = result.core.allChars;

			static foreach(enum I, alias Arg; Args){
				static if(isBasicString!Arg)
					data = data[args[I].core.chars.encodeTo(data) .. $];
				else static if(isArray!Arg)
					data = data[args[I][].encodeTo(data) .. $];
				else static if(isSomeChar!Arg)
					data = data[args[I].encodeTo(data) .. $];
				else static assert(0, "wrong type '" ~ Arg.stringof ~ "'");
			}

			result.core.length = new_length;
		}


		/*
			Core
		*/
		private Core core;
	}
}



/// Alias to `BasicString` with different order of template parameters
template BasicString(
	_Char,
	size_t _Padding,
	_Allocator = Mallocator
)
if(isSomeChar!_Char && is(Unqual!_Char == _Char)){
	alias BasicString = .BasicString!(_Char, _Allocator, _Padding);
}



///
pure nothrow @safe @nogc unittest {
	import std.experimental.allocator.mallocator : Mallocator;

	alias String = BasicString!(
		char,               //character type
		Mallocator,         //allocator type (can be stateless or with state)
		32                  //additional padding to increas max size of small string (small string does not allocate memory).
	);

	//copy:
	{
		String a = "123";
		String b = a;

		a = "456"d;

		assert(a == "456");
		assert(b == "123");
	}


	//append:
	{
		String str = "12";

		str.append("34");   //same as str += "34"
		str.append("56"w);  //same as str += "56"w
		str.append(7);      //same as str += 7;
		str.append('8');

		assert(str == "12345678");

		str.clear();

		assert(str.empty);
	}

	//erase:
	{
		String str = "123456789";

		str.erase(2, 2);

		assert(str == "1256789");
	}

	//insert:
	{
		String str = "123456789";

		str.insert(1, "xyz");

		assert(str == "1xyz23456789");
	}

	//replace:
	{
		String str = "123456789";

		str.replace(1, 2, "xyz");

		assert(str == "1xyz456789");
	}

	//slice to string:
	()@trusted{
		String str = "123456789";

		const(char)[] dstr = str[];

		assert(str == dstr);
	}();
}

//doc:
version(unittest){
	//doc.minimalCapacity:
	pure nothrow @safe @nogc unittest{
		BasicString!char str;
		assert(str.empty);
		assert(str.capacity == BasicString!char.minimalCapacity);
		assert(str.capacity > 0);
	}

	//doc.empty:
	pure nothrow @safe @nogc unittest{
		BasicString!char str;
		assert(str.empty);

		str = "123";
		assert(!str.empty);
	}

	//doc.length:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";
		assert(str.length == 3);

		BasicString!wchar wstr = "123";
		assert(wstr.length == 3);

		BasicString!dchar dstr = "123";
		assert(dstr.length == 3);
	}

	//doc.capacity:
	pure nothrow @safe @nogc unittest{
		BasicString!char str;
		assert(str.capacity == BasicString!char.minimalCapacity);

		str.reserve(str.capacity + 1);
		assert(str.capacity > BasicString!char.minimalCapacity);
	}

	//doc.ptr:
	pure nothrow @system @nogc unittest{
		BasicString!char str = "123";
		char* ptr = str.ptr;
		assert(ptr[0 .. 3] == "123");
	}

	//doc.frontCodePoint:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "á123";

		assert(str.frontCodePoint == 'á');
	}

	//doc.frontCodeUnit:
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = "123";

			assert(str.frontCodeUnit == '1');
		}

		{
			BasicString!char str = "á23";

			immutable(char)[2] a = "á";
			assert(str.frontCodeUnit == a[0]);
		}

		{
			BasicString!char str = "123";

			str.frontCodeUnit = 'x';

			assert(str == "x23");
		}
	}

	//doc.backCodePoint:
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = "123á";

			assert(str.backCodePoint == 'á');
		}

		{
			BasicString!char str = "123á";
			str.backCodePoint = '4';
			assert(str == "1234");
		}
	}

	//doc.backCodeUnit:
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = "123";

			assert(str.backCodeUnit == '3');
		}

		{
			BasicString!char str = "12á";

			immutable(char)[2] a = "á";
			assert(str.backCodeUnit == a[1]);
		}

		{
			BasicString!char str = "123";

			str.backCodeUnit = 'x';
			assert(str == "12x");
		}
	}

	//doc.popBackCodePoint:
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = "á1";    //'á' is encoded as 2 chars

			assert(str.popBackCodePoint == 1);
			assert(str == "á");

			assert(str.popBackCodePoint == 2);
			assert(str.empty);

			assert(str.popBackCodePoint == 0);
			assert(str.empty);
		}

		{
			BasicString!char str = "1á";    //'á' is encoded as 2 chars
			assert(str.length == 3);

			str.erase(str.length - 1);
			assert(str.length == 2);

			assert(str.popBackCodePoint == 0);   //popBackCodePoint cannot remove invalid code points
			assert(str.length == 2);
		}
	}

	//doc.popBackCodeUnit:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "á1";    //'á' is encoded as 2 chars
		assert(str.length == 3);

		assert(str.popBackCodeUnit);
		assert(str.length == 2);

		assert(str.popBackCodeUnit);
		assert(str.length == 1);

		assert(str.popBackCodeUnit);
		assert(str.empty);

		assert(!str.popBackCodeUnit);
		assert(str.empty);

	}

	//doc.clear:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";

		str.reserve(str.capacity * 2);
		assert(str.length == 3);

		const size_t cap = str.capacity;
		str.clear();
		assert(str.capacity == cap);

	}

	//doc.release:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";

		str.reserve(str.capacity * 2);
		assert(str.length == 3);

		const size_t cap = str.capacity;
		str.clear();
		assert(str.capacity == cap);

		str.release();
		assert(str.capacity < cap);
		assert(str.capacity == BasicString!char.minimalCapacity);

	}

	//doc.reserve:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";
		assert(str.capacity == BasicString!char.minimalCapacity);

		const size_t cap = (str.capacity * 2);
		str.reserve(cap);
		assert(str.capacity > BasicString!char.minimalCapacity);
		assert(str.capacity >= cap);

	}

	//doc.reserve:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";
		assert(str.capacity == BasicString!char.minimalCapacity);

		const size_t cap = (str.capacity * 2);
		str.reserve(cap);
		assert(str.capacity > BasicString!char.minimalCapacity);
		assert(str.capacity >= cap);
	}

	//doc.resize:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";

		str.resize(5, 'x');
		assert(str == "123xx");

		str.resize(2);
		assert(str == "12");

	}

	//doc.shrinkToFit:
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";
		assert(str.capacity == BasicString!char.minimalCapacity);

		str.reserve(str.capacity * 2);
		assert(str.capacity > BasicString!char.minimalCapacity);

		str.shrinkToFit();
		assert(str.capacity == BasicString!char.minimalCapacity);
	}

	//doc.ctor(null):
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = null;
			assert(str.empty);
		}
	}

	//doc.ctor(allocator):
	pure nothrow @safe @nogc unittest{
		{
			BasicString!(char, Mallocator) str = Mallocator.init;
			assert(str.empty);
		}
	}

	//doc.ctor(character):
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = 'x';
			assert(str == "x");
		}

		{
			BasicString!char str = '読';
			assert(str == "読");
		}
	}

	//doc.ctor(character, allocator):
	pure nothrow @safe @nogc unittest{
		{
			auto str = BasicString!(char, Mallocator)('読', Mallocator.init);
			assert(str == "読");
		}
	}

	//doc.ctor(slice):
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = "test";
			assert(str == "test");
		}

		{
			BasicString!char str = "test 読"d;
			assert(str == "test 読");
		}

		{
			wchar[3] data = [cast(wchar)'1', '2', '3'];
			BasicString!char str = data[];
			assert(str == "123");
		}
	}

	//doc.ctor(slice, allocator):
	pure nothrow @safe @nogc unittest{
		{
			auto str = BasicString!(char, Mallocator)("test", Mallocator.init);
			assert(str == "test");
		}

		{
			auto str = BasicString!(char, Mallocator)("test 読"d, Mallocator.init);
			assert(str == "test 読");
		}

		{
			wchar[3] data = [cast(wchar)'1', '2', '3'];
			auto str = BasicString!(char, Mallocator)(data[], Mallocator.init);
			assert(str == "123");
		}
	}

	//doc.ctor(integer):
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = 123uL;
			assert(str == "123");
		}

		{
			BasicString!dchar str = -123;
			assert(str == "-123");
		}
	}

	//doc.ctor(integer, allocator):
	pure nothrow @safe @nogc unittest{
		{
			auto str = BasicString!(char, Mallocator)(123uL, Mallocator.init);
			assert(str == "123");
		}

		{
			auto str = BasicString!(dchar, Mallocator)(-123, Mallocator.init);
			assert(str == "-123");
		}
	}

	//doc.ctor(rhs):
	//doc.ctor(rhs, allcoator):
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char a = "123";
			BasicString!char b = a;
			assert(b == "123");
		}

		{
			BasicString!dchar a = "123";
			BasicString!char b = a;
			assert(b == "123");
		}

		{
			BasicString!dchar a = "123";
			auto b = BasicString!char(a, Mallocator.init);
			assert(b == "123");
		}

		import core.lifetime : move;
		{
			BasicString!char a = "123";
			BasicString!char b = move(a);
			assert(b == "123");
		}

	}

	//doc.opAssign(null):
	//doc.opAssign(slice):
	//doc.opAssign(character):
	//doc.opAssign(integer):
	//doc.opAssign(rhs):
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";
		assert(!str.empty);

		str = null;
		assert(str.empty);

		str = 'X';
		assert(str == "X");

		str = "abc"w;
		assert(str == "abc");

		str = -123;
		assert(str == "-123");

		str = BasicString!char("42");
		assert(str == "42");

		str = BasicString!wchar("abc");
		assert(str == "abc");

	}

	//doc.opBinary(rhs):
	pure nothrow @safe @nogc unittest{
		BasicString!char str = null;
		assert(str.empty);

		str = str + '1';
		assert(str == "1");

		str = str + "23"d;
		assert(str == "123");

		str = str + BasicString!dchar("456");
		assert(str == "123456");

	}

	//doc.opBinaryRight(rhs):
	pure nothrow @safe @nogc unittest{
		BasicString!char str = null;
		assert(str.empty);

		str = '1' + str;
		assert(str == "1");

		str = "32"d + str;
		assert(str == "321");

		str = BasicString!dchar("654") + str;
		assert(str == "654321");
	}

	//doc.opEquals(rhs):
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "123";

		assert(str == "123");
		assert("123" == str);

		assert(str == "123"w);
		assert("123"w == str);

		assert(str == "123"d);
		assert("123"d == str);

		assert(str == BasicString!wchar("123"));
		assert(BasicString!wchar("123") == str);

		assert(str == 123);
		assert(123 == str);

		import std.range : only;
		assert(str == only('1', '2', '3'));
		assert(only('1', '2', '3') == str);
	}

	//doc.opCmp(rhs):
	pure nothrow @safe @nogc unittest{

	}

	//doc.opIndex():
	pure nothrow @system @nogc unittest{
		BasicString!char str = "123";

		char[] slice = str[];
		assert(slice.length == str.length);
		assert(slice.ptr is str.ptr);

		str.reserve(str.capacity * 2);
		assert(slice.length == str.length);
		assert(slice.ptr !is str.ptr);  // slice contains dangling pointer.

	}

	//doc.opIndex(pos):
	pure nothrow @system @nogc unittest{
		BasicString!char str = "abcd";

		assert(str[1] == 'b');
	}

	//doc.opSlice(begin, end):
	pure nothrow @system @nogc unittest{
		BasicString!char str = "123456";

		assert(str[1 .. $-1] == "2345");
	}

	//doc.opIndexAssign(begin, end):
	pure nothrow @safe @nogc unittest{
		BasicString!char str = "abcd";

		str[1] = 'x';

		assert(str == "axcd");
	}

	//doc.proxySwap(rhs):
	pure nothrow @safe @nogc unittest{
		BasicString!char a = "1";
		BasicString!char b = "2";

		a.proxySwap(b);
		assert(a == "2");
		assert(b == "1");

		import std.algorithm.mutation : swap;

		swap(a, b);
		assert(a == "1");
		assert(b == "2");
	}

	//doc.append(val, count):
	pure nothrow @safe @nogc unittest{
		{
			BasicString!char str = "123456";

			str.append('x', 2);
			assert(str == "123456xx");
		}

		{
			BasicString!char str = "123456";

			str.append("abc");
			assert(str == "123456abc");
		}

		{
			BasicString!char str = "123456";
			BasicString!char str2 = "xyz";

			str.append(str2);
			assert(str == "123456xyz");
		}

		{
			BasicString!char str = "12";

			str.append(+34);
			assert(str == "1234");
		}
	}

	//doc.insert(pos, val, count):
	//doc.insert(ptr, val, count):
	pure nothrow @system @nogc unittest{
		{
			BasicString!char str = "123456";

			str.insert(2, 'x', 2);
			assert(str == "12xx3456");
		}

		{
			BasicString!char str = "123456";

			str.insert(2, "abc");
			assert(str == "12abc3456");
		}

		{
			BasicString!char str = "123456";
			BasicString!char str2 = "abc";

			str.insert(2, str2);
			assert(str == "12abc3456");
		}

		{
			BasicString!char str = "123456";

			str.insert(str.ptr + 2, 'x', 2);
			assert(str == "12xx3456");
		}

		{
			BasicString!char str = "123456";

			str.insert(str.ptr + 2, "abc");
			assert(str == "12abc3456");
		}

		{
			BasicString!char str = "123456";
			BasicString!char str2 = "abc";

			str.insert(str.ptr + 2, str2);
			assert(str == "12abc3456");
		}
	}


	//doc.erase(pos):
	//doc.erase(pos, n):
	//doc.erase(ptr):
	//doc.erase(slice):
	pure nothrow @system @nogc unittest{
		{
			BasicString!char str = "123456";

			str.erase(2);
			assert(str == "12");
		}

		{
			BasicString!char str = "123456";

			str.erase(1, 2);
			assert(str == "1456");
		}

		{
			BasicString!char str = "123456";

			str.erase(str.ptr + 2);
			assert(str == "12");
		}

		{
			BasicString!char str = "123456";

			str.erase(str[1 .. $-1]);
			assert(str == "16");
		}
	}


	//doc.replace(pos, len val, count):
	//doc.replace(slice, val, count):
	pure nothrow @system @nogc unittest{
		{
			BasicString!char str = "123456";

			str.replace(2, 2, 'x', 5);
			assert(str == "12xxxxx56");
		}

		{
			BasicString!char str = "123456";

			str.replace(2, 2, "abcdef");
			assert(str == "12abcdef56");
		}

		{
			BasicString!char str = "123456";
			BasicString!char str2 = "xy";

			str.replace(2, 3, str2);
			assert(str == "12xy56");
		}

		{
			BasicString!char str = "123456";

			str.replace(str[2 .. 4], 'x', 5);
			assert(str == "12xxxxx56");
		}

		{
			BasicString!char str = "123456";

			str.replace(str[2 .. 4], "abcdef");
			assert(str == "12abcdef56");
		}

		{
			BasicString!char str = "123456";
			BasicString!char str2 = "xy";

			str.replace(str[2 .. $], str2);
			assert(str == "12xy56");
		}
	}


	//doc.build(...):
	pure nothrow @system @nogc unittest{
		BasicString!char str = BasicString!char.build('1', cast(dchar)'2', "345"d, BasicString!wchar("678"));

		assert(str == "12345678");

	}


}



//normal ut
version(unittest){
	version(basic_string_unittest)
	struct TestStatelessAllocator(bool Realloc){
		import std.experimental.allocator.common : stateSize;

		private struct Allocation{
			void[] alloc;
			long count;


			this(void[] alloc, long c)pure nothrow @safe @nogc{
				this.alloc = alloc;
				this.count = c;
			}
		}

		private static Allocation[] allocations;
		private static void[][] bad_dealocations;


		private void add(void[] b)scope nothrow @trusted{
			if(b.length == 0)
				return;

			foreach(ref a; allocations){
				if(a.alloc.ptr is b.ptr && a.alloc.length == b.length){
					a.count += 1;
					return;
				}
			}

			allocations ~= Allocation(b, 1);
		}

		private void del(void[] b)scope nothrow @trusted{
			foreach(ref a; allocations){
				if(a.alloc.ptr is b.ptr && a.alloc.length == b.length){
					a.count -= 1;
					return;
				}
			}

			bad_dealocations ~= b;
		}


		import std.experimental.allocator.common : platformAlignment;

		public enum uint alignment = platformAlignment;

		public void[] allocate(size_t bytes)scope @trusted nothrow{
			auto data = Mallocator.instance.allocate(bytes);
			if(data.length == 0)
				return null;

			this.add(data);

			return data;
		}

		public bool deallocate(void[] b)scope @system nothrow{
			const result = Mallocator.instance.deallocate(b);
			assert(result);

			this.del(b);

			return result;

		}

		public bool reallocate(ref void[] b, size_t s)scope @system nothrow{
			static if(Realloc){
				void[] old = b;

				const result = Mallocator.instance.reallocate(b, s);

				this.del(old);
				this.add(b);

				return result;

			}
			else return false;
		}


		public bool empty()scope const nothrow @safe @nogc{
			import std.algorithm : all;

			return true
				&& bad_dealocations.length == 0
				&& allocations.all!((a) => a.count == 0);

		}

		static typeof(this) instance;
	}

	version(basic_string_unittest)
	class TestStateAllocator(bool Realloc){
		import std.experimental.allocator.common : stateSize;

		private struct Allocation{
			void[] alloc;
			long count;


			this(void[] alloc, long c)pure nothrow @safe @nogc{
				this.alloc = alloc;
				this.count = c;
			}
		}

		private Allocation[] allocations;
		private void[][] bad_dealocations;


		private void add(void[] b)scope nothrow @trusted{
			if(b.length == 0)
				return;

			foreach(ref a; allocations){
				if(a.alloc.ptr is b.ptr && a.alloc.length == b.length){
					a.count += 1;
					return;
				}
			}

			allocations ~= Allocation(b, 1);
		}

		private void del(void[] b)scope nothrow @trusted{
			foreach(ref a; allocations){
				if(a.alloc.ptr is b.ptr && a.alloc.length == b.length){
					a.count -= 1;
					return;
				}
			}

			bad_dealocations ~= b;
		}


		import std.experimental.allocator.common : platformAlignment;

		public enum uint alignment = platformAlignment;

		public void[] allocate(size_t bytes)scope @trusted nothrow{
			auto data = Mallocator.instance.allocate(bytes);
			if(data.length == 0)
				return null;

			this.add(data);

			return data;
		}

		public bool deallocate(void[] b)scope @system nothrow{
			const result = Mallocator.instance.deallocate(b);
			assert(result);

			this.del(b);

			return result;

		}

		public bool reallocate(ref void[] b, size_t s)scope @system nothrow{
			static if(Realloc){
				void[] old = b;

				const result = Mallocator.instance.reallocate(b, s);

				this.del(old);
				this.add(b);

				return result;

			}
			else return false;
		}


		public bool empty()scope const nothrow @safe @nogc{
			import std.algorithm : all;

			return true
				&& bad_dealocations.length == 0
				&& allocations.all!((a) => a.count == 0);

		}
	}




	version(basic_string_unittest){
		private auto trustedSlice(S)(auto ref scope S str)@trusted{
			return str[];
		}
		private auto trustedSlice(S)(auto ref scope S str, size_t b, size_t e)@trusted{
			return str[b .. e];
		}
		private auto trustedSliceToEnd(S)(auto ref scope S str, size_t b)@trusted{
			return str[b .. $];
		}

		void unittest_allocator_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			Str str = Str("1", allocatorWithState);
			auto a = str.allocator;
		}

		void unittest_reserve_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			///reserve:
			Str str = Str("1", allocatorWithState);
			assert(str.capacity == Str.minimalCapacity);
			//----------------------------
			const size_t new_capacity = str.capacity * 2 + 1;
			str.reserve(new_capacity);
			assert(str.capacity > new_capacity);
			//----------------------------
			str.clear();
			assert(str.empty);
		}

		void unittest_resize_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			///resize:
			Str str = Str("1", allocatorWithState);
			assert(str.capacity == Str.minimalCapacity);
			//----------------------------
			str.resize(Str.minimalCapacity);
			assert(str.capacity == Str.minimalCapacity);
			assert(str.length == Str.minimalCapacity);
			//----------------------------
			str.resize(Str.minimalCapacity - 1, '_');
			assert(str.capacity == Str.minimalCapacity);
			assert(str.length == Str.minimalCapacity - 1);
			//----------------------------
			str.resize(Str.minimalCapacity + 3, '_');
			assert(str.capacity > Str.minimalCapacity);
			assert(str.length == Str.minimalCapacity + 3);

		}


		void unittest_ctor_string_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(enum val; AliasSeq!(
				"0123",
				"0123456789_0123456789_0123456789_0123456789",
			))
			static foreach(enum I; AliasSeq!(1, 2, 3, 4)){{
				static if(I == 1){
					char[val.length] s = val;
					wchar[val.length] w = val;
					dchar[val.length] d = val;
				}
				else static if(I == 2){
					immutable(char)[val.length] s = val;
					immutable(wchar)[val.length] w = val;
					immutable(dchar)[val.length] d = val;
				}
				else static if(I == 3){
					enum string s = val;
					enum wstring w = val;
					enum dstring d = val;
				}
				else static if(I == 4){
					auto s = BasicString!(char, Allocator)(val, allocatorWithState);
					auto w = BasicString!(wchar, Allocator)(val, allocatorWithState);
					auto d = BasicString!(dchar, Allocator)(val, allocatorWithState);
				}
				else static assert(0, "no impl");

				auto str1 = Str(s, allocatorWithState);
				str1 = s;
				auto str2 = Str(s.trustedSlice, allocatorWithState);
				str2 = s.trustedSlice;
				assert(str1 == str2);

				auto wstr1 = Str(w, allocatorWithState);
				wstr1 = w;
				auto wstr2 = Str(w.trustedSlice, allocatorWithState);
				wstr2 = w.trustedSlice;
				assert(wstr1 == wstr2);

				auto dstr1 = Str(d, allocatorWithState);
				dstr1 = d;
				auto dstr2 = Str(d.trustedSlice, allocatorWithState);
				dstr2 = d.trustedSlice;
				assert(dstr1 == dstr2);
			}}


		}

		void unittest_ctor_char_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(enum val; AliasSeq!(
				cast(char)'1',
				cast(wchar)'2',
				cast(dchar)'3',
			))
			static foreach(enum I; AliasSeq!(1, 2, 3)){{
				static if(I == 1){
					char c = val;
					wchar w = val;
					dchar d = val;
				}
				else static if(I == 2){
					immutable(char) c = val;
					immutable(wchar) w = val;
					immutable(dchar) d = val;
				}
				else static if(I == 3){
					enum char c = val;
					enum wchar w = val;
					enum dchar d = val;
				}
				else static assert(0, "no impl");

				auto str = Str(c, allocatorWithState);
				str = c;

				auto wstr = Str(w, allocatorWithState);
				wstr = w;

				auto dstr = Str(d, allocatorWithState);
				dstr = d;
			}}

		}


		void unittest_shrink_to_fit_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			Str str = Str("123", allocatorWithState);
			assert(str.capacity == Str.minimalCapacity);

			//----------------------------
			assert(str.small);
			str.resize(str.capacity * 2, 'x');
			assert(!str.small);


			const size_t cap = str.capacity;
			const size_t len = str.length;
			str.shrinkToFit();
			assert(str.length == len);
			assert(str.capacity == cap);

			str = "123";
			assert(str.length == 3);
			assert(str.capacity == cap);

			str.shrinkToFit();
			assert(str.length == 3);
			assert(str.capacity == Str.minimalCapacity);

			//----------------------------
			str.clear();
			assert(str.empty);

		}


		void unittest_operator_plus_string_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(enum I; AliasSeq!(1, 2, 3, 4)){{
				static if(I == 1){
					auto s = BasicString!(char, Allocator)("45", allocatorWithState);
					auto w = BasicString!(wchar, Allocator)("67", allocatorWithState);
					auto d = BasicString!(dchar, Allocator)("89", allocatorWithState);
				}
				else static if(I == 2){
					immutable(char)[2] s = "45";
					immutable(wchar)[2] w = "67";
					immutable(dchar)[2] d = "89";
				}
				else static if(I == 3){
					enum string s = "45";
					enum wstring w = "67";
					enum dstring d = "89";
				}
				else static if(I == 4){
					char[2] sx = ['4', '5'];
					wchar[2] wx = ['6', '7'];
					dchar[2] dx = ['8', '9'];
					char[] s = sx[];
					wchar[] w = wx[];
					dchar[] d = dx[];
				}
				else static assert(0, "no impl");


				Str str = Str("123", allocatorWithState);
				assert(str.capacity == Str.minimalCapacity);

				////----------------------------
				str = (str + s);
				str = (s + str);
				str += s;
				assert(str == "451234545");

				str = (str + w);
				str = (w + str);
				str += w;
				assert(str == "674512345456767");

				str = (str + d);
				str = (d + str);
				str += d;
				assert(str == "896745123454567678989");

				//----------------------------
				str.clear();
				assert(str.empty);
			}}
		}

		void unittest_operator_plus_char_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(enum I; AliasSeq!(1, 2)){{
				static if(I == 1){
					char c = 'a';
					wchar w = 'b';
					dchar d = 'c';
				}
				else static if(I == 2){
					enum char c = 'a';
					enum wchar w = 'b';
					enum dchar d = 'c';
				}
				else static assert(0, "no impl");


				Str str = Str("123", allocatorWithState);
				assert(str.capacity == Str.minimalCapacity);

				////----------------------------
				str = (str + c);
				str = (c + str);
				str += c;
				assert(str == "a123aa");

				str = (str + w);
				str = (w + str);
				str += w;
				assert(str == "ba123aabb");

				str = (str + d);
				str = (d + str);
				str += d;
				assert(str == "cba123aabbcc");

				//----------------------------
				str.clear();
				assert(str.empty);
			}}
		}


		void unittest_append_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(enum val; AliasSeq!(
				"0123",
				"0123456789_0123456789_0123456789_0123456789",
			))
			static foreach(enum rep; AliasSeq!(
				'x',
				"",
				"a",
				"ab",
				"abcdefgh_abcdefgh_abcdefgh_abcdefgh",
			))
			static foreach(enum size_t count; AliasSeq!(0, 1, 2, 3))
			static foreach(alias T; AliasSeq!(char, wchar, dchar)){{
				import std.traits : isArray;

				static if(isArray!(typeof(rep)))
					alias Rep = immutable(T)[];
				else
					alias Rep = T;


				Str str = Str(val, allocatorWithState);

				str.append(cast(Rep)rep, count);


				Str rep_complet = Str(allocatorWithState);
				for(size_t i = 0; i < count; ++i)
					rep_complet += cast(Rep)rep;

				import std.range;
				assert(str == Str.build(allocatorWithState, val, rep_complet.trustedSlice));
				//assert(str == chain(val, rep_complet[]));

			}}

		}

		void unittest_insert_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(enum val; AliasSeq!(
				"0123",
				"0123456789_0123456789_0123456789_0123456789",
			))
			static foreach(enum rep_source; AliasSeq!(
				'x',
				"",
				"a",
				"ab",
				"abcdefgh_abcdefgh_abcdefgh_abcdefgh",
			))
			static foreach(enum size_t count; AliasSeq!(0, 1, 2, 3))
			static foreach(alias T; AliasSeq!(char, wchar, dchar)){{
				import std.traits : isArray;

				static if(isArray!(typeof(rep_source)))
					enum immutable(T)[] rep = rep_source;
				else
					enum T rep = rep_source;


				Str rep_complet = Str(allocatorWithState);
				for(size_t i = 0; i < count; ++i)
					rep_complet += rep;

				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert(2, rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, val.trustedSlice(0, 2), rep_complet, val.trustedSliceToEnd(2)));
				}
				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert(str.length, rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, val, rep_complet));
				}
				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert(str.length + 2000, rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, val, rep_complet));
				}
				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert(0, rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, rep_complet, val));
				}
				//------------------------------------------------
				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert((()@trusted => str.ptr + 2)(), rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, val.trustedSlice(0, 2), rep_complet, val.trustedSliceToEnd(2)));
				}
				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert((()@trusted => str.ptr + str.length)(), rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, val, rep_complet));
				}
				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert((()@trusted => str.ptr + str.length + 2000)(), rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, val, rep_complet));
				}
				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert((()@trusted => str.ptr)(), rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, rep_complet, val));
				}
				{
					Str str = Str(val, allocatorWithState);

					const x = str.insert((()@trusted => str.ptr - 1000)(), rep, count);
					assert(Str(rep, allocatorWithState).length * count == x);
					assert(str == Str.build(allocatorWithState, rep_complet, val));
				}

			}}
		}

		void unittest_erase_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(enum val; AliasSeq!(
				"0123",
				"0123456789_0123456789_0123456789_0123456789",
			)){
				{
					Str str = Str(val, allocatorWithState);

					str.erase(2);
					//assert(str.equals_test(Str(val[0 .. 2])));
					assert(str == Str(val[0 .. 2], allocatorWithState));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.erase(1, 2);
					assert(str == Str.build(allocatorWithState, val[0 .. 1], val[3 .. $]));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.erase(1, 1000);
					assert(str == Str.build(allocatorWithState, val[0 .. 1]));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.erase(str.trustedSliceToEnd(2));
					assert(str == Str.build(allocatorWithState, val[0 .. 2]));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.erase(str.trustedSlice(1, 3));
					assert(str == Str.build(allocatorWithState, val.trustedSlice(0, 1), val.trustedSliceToEnd(3)));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.erase((()@trusted => str.ptr + 2)());
					assert(str == Str(val.trustedSlice(0, 2), allocatorWithState));
				}
			}

			///downsize (erase):
			{
				Str str = Str("123", allocatorWithState);
				assert(str.length == 3);

				//----------------------------
				str.erase(3);
				assert(str.length == 3);

				str.erase(1000);
				assert(str.length == 3);

				str.erase(1);
				assert(str.length == 1);

				//----------------------------
				const size_t new_length = str.capacity * 2;
				str.resize(new_length);
				assert(str.capacity >= new_length);
				assert(str.length == new_length);

				str.erase(3);
				assert(str.length == 3);

				str.erase(1000);
				assert(str.length == 3);

				str.erase(1);
				assert(str.length == 1);

				//----------------------------
				str.clear();
				assert(str.empty);
			}
		}

		void unittest_replace_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(enum val; AliasSeq!(
				"0123",
				"0123456789_0123456789_0123456789_0123456789",
			))
			static foreach(enum rep_source; AliasSeq!(
				'x',
				"",
				"a",
				"ab",
				"abcdefgh_abcdefgh_abcdefgh_abcdefgh",
			))
			static foreach(enum size_t count; AliasSeq!(0, 1, 2, 3))
			static foreach(alias T; AliasSeq!(char, wchar, dchar)){{
				import std.traits : isArray;

				static if(isArray!(typeof(rep_source)))
					enum immutable(T)[] rep = rep_source;
				else
					enum T rep = rep_source;


				Str rep_complet = Str(allocatorWithState);
				for(size_t i = 0; i < count; ++i)
					rep_complet += rep;

				{
					Str str = Str(val, allocatorWithState);

					str.replace(1, 2, rep, count);
					//debug writeln(val, ": ", str[], " vs ", val[0 .. 1], " | ", rep_complet[], " | ", val[3 .. $]);
					//assert(str[] == Str.build(val[0 .. 1], rep_complet[], val[3 .. $]));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.replace(1, val.length - 1, rep, count);
					//assert(str[] == Str.build(val[0 .. 1], rep_complet[]));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.replace(1, val.length + 2000, rep, count);
					//assert(str[] == Str.build(val[0 .. 1], rep_complet[]));
				}
				//------------------------
				{
					Str str = Str(val, allocatorWithState);

					str.replace((()@trusted => str[1 .. $ - 1])(), rep, count);
					//assert(str[] == Str.build(val[0 .. 1], rep_complet[], val[$ - 1 .. $]));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.replace((()@trusted => str[1 ..  $])(), rep, count);
					//assert(str[] == Str.build(val[0 .. 1], rep_complet[]));
				}
				{
					Str str = Str(val, allocatorWithState);

					str.replace((()@trusted => str.ptr[1 .. str.length + 2000])(), rep, count);
					//assert(str[] == Str.build(val[0 .. 1], rep_complet[]));
				}

			}}
		}


		void unittest_output_range_impl(Char, Allocator)(Allocator allocator){
			alias Str = BasicString!(Char, Allocator);

			static if(Str.hasStatelessAllocator)
				alias allocatorWithState = AliasSeq!();
			else
				alias allocatorWithState = AliasSeq!(allocator);

			static foreach(alias T; AliasSeq!(char, wchar, dchar)){{
				import std.range : only;
				import std.algorithm.mutation : copy;

				{
					Str str = only(
						cast(immutable(T)[])"a",
						cast(immutable(T)[])"bc",
						cast(immutable(T)[])"",
						cast(immutable(T)[])"d"
					).copy(Str(allocatorWithState));

				}
				{
					Str str = only(
						cast(T)'a',
						cast(T)'b',
						cast(T)'c'
					).copy(Str(allocatorWithState));

					assert(str == Str("abc", allocatorWithState));

				}
			}}
		}

	}


	version(basic_string_unittest)
	void unittest_impl(Char, Allocator)(Allocator allocator){
		unittest_allocator_impl!Char(allocator);

		unittest_reserve_impl!Char(allocator);
		unittest_resize_impl!Char(allocator);

		unittest_ctor_string_impl!Char(allocator);
		unittest_ctor_char_impl!Char(allocator);

		unittest_shrink_to_fit_impl!Char(allocator);

		unittest_operator_plus_string_impl!Char(allocator);
		unittest_operator_plus_char_impl!Char(allocator);

		unittest_append_impl!Char(allocator);
		unittest_insert_impl!Char(allocator);
		unittest_erase_impl!Char(allocator);
		unittest_replace_impl!Char(allocator);

		unittest_output_range_impl!Char(allocator);

	}



	version(basic_string_unittest)
	void unittest_impl(Allocator)(Allocator allocator = Allocator.init){
		import std.stdio : writeln;
		import std.range : only;
		import std.experimental.allocator.common : stateSize;

		static foreach(alias Char; AliasSeq!(char, wchar, dchar))
			unittest_impl!Char(allocator);

	}

	version(basic_string_unittest)
	@nogc @safe pure nothrow unittest{
		unittest_impl!Mallocator();
	}

	version(basic_string_unittest)
	nothrow unittest{
		version(D_BetterC){}
		else{
			static foreach(enum bool Realloc; [false, true]){
				{
					alias AX = TestStatelessAllocator!Realloc;

					assert(AX.instance.empty);

					unittest_impl!AX();

					assert(AX.instance.empty);
				}

				{
					alias AX = TestStateAllocator!Realloc;

					auto allocator = new AX;


					assert(allocator.empty);

					unittest_impl(allocator);

					assert(allocator.empty);


					//unittest_impl(allocator);

				}

				{
					alias AX = TestStateAllocator!Realloc;
					auto allocator = new AX;

					assert(allocator.empty);

					{
						alias Str = BasicString!(char, AX);

						//Str b;
						//auto a = Str(allocator, "0123456789_0123456789_0123456789_");

					}

					assert(allocator.empty);

				}
			}
		}
	}

}



