# Basic Template Library

## Documentation
https://submada.github.io/btl

## About
This is colection of subbackages:
  
- `btl:autoptr`: smart pointers like c++ `std::shared_ptr`, `std::weak_ptr`, `std::enable_shared_from_this` and more.
  - [SharedPtr](https://submada.github.io/btl/btl/autoptr/shared_ptr/SharedPtr.html) reference counted pointer with support for aliasing
  - [RcPtr](https://submada.github.io/btl/btl/autoptr/rc_ptr/RcPtr.html) reference counted pointer with limited support for aliasing (but small size and lock free manipulation of shared ptr)
  - [IntrusivePtr](https://submada.github.io/btl/btl/autoptr/intrusive_ptr/IntrusivePtr.html) reference counted pointer with ref counting inside of conted object.
  - [UniquePtr](https://submada.github.io/btl/btl/autoptr/unique_ptr/UniquePtr.html) non copyable owning pointer that owns and manages object through a pointer and disposes of that object when goes out of scope. 
- [btl:vector](https://submada.github.io/btl/btl/vector.html) dynamic array like c++ `std::vector` and `folly::small_vector`
  - [Vector](https://submada.github.io/btl/btl/vector/Vector.html) sequence container with growable capacity.
  - [SmallVector](https://submada.github.io/btl/btl/vector/SmallVector.html) sequence container with growable capacity that implements small buffer optimization for `N` elements.
  - [FixedVector](https://submada.github.io/btl/btl/vector/FixedVector.html) sequence container with max `N` elements.
- [btl:string](https://submada.github.io/btl/btl/string.html) mutable string with small string optimization like c++ `std::basic_string` and `std::string`
  - [BasicString](https://submada.github.io/btl/btl/string/BasicString.html) The `BasicString` is the generalization of struct string for character type char, wchar and dchar.
  - [String](https://submada.github.io/btl/btl/string/String.html) alias to `BasicString!char`.
