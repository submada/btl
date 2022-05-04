# Basic Template Library

## About
This is colection of packages:

- **btl:autoptr**: smart pointers like c++ `std::shared_ptr`, `std::weak_ptr`, `std::enable_shared_from_this` and more.
  - [SharedPtr](https://submada.github.io/btl/btl/autoptr/shared_ptr/SharedPtr.html) reference counted pointer with support for aliasing and optional weak pointer support
  - [RcPtr](https://submada.github.io/btl/btl/autoptr/rc_ptr/RcPtr.html) reference counted pointer with limited support for aliasing (but small size and lock free manipulation of pointer) and optional weak pointer support.
  - [IntrusivePtr](https://submada.github.io/btl/btl/autoptr/intrusive_ptr/IntrusivePtr.html) reference counted pointer with reference counting inside of managed object with limited support for aliasing (but small size and lock free manipulation of pointer) and optional weak pointer support.
  - [UniquePtr](https://submada.github.io/btl/btl/autoptr/unique_ptr/UniquePtr.html) non copyable owning pointer that owns and manages object through a pointer and disposes of that object when goes out of scope.
  - [GlobalPtr (beta)](https://submada.github.io/btl/btl/autoptr/global_ptr/GlobalPtr.html)
- **btl:string** mutable string with small string optimization like c++ `std::basic_string` and `std::string`
  - [BasicString](https://submada.github.io/btl/btl/string/BasicString.html) Generalization of struct string with optional small string optimization for min `N` characters of type char, wchar and dchar.
  - [SmallString](https://submada.github.io/btl/btl/string/SmallString.html) Generalization of struct string with small string optimization for min `N` characters of type char, wchar and dchar.
  - [LargeString](https://submada.github.io/btl/btl/string/LargeString.html) Generalization of struct string without small string optimization for characters of type char, wchar and dchar.
  - [FixedString](https://submada.github.io/btl/btl/string/FixedString.html) Generalization of struct string with max `N` characters of type char, wchar and dchar.
  - [String](https://submada.github.io/btl/btl/string/String.html) alias to `BasicString!char`.
- **btl:vector** dynamic array like c++ `std::vector` and `folly::small_vector`
  - [Vector](https://submada.github.io/btl/btl/vector/Vector.html) sequence container with growable capacity.
  - [SmallVector](https://submada.github.io/btl/btl/vector/SmallVector.html) sequence container with growable capacity that implements small buffer optimization for `N` elements.
  - [FixedVector](https://submada.github.io/btl/btl/vector/FixedVector.html) sequence container with max `N` elements.
- **btl:list (beta)** linked list like c++ `std::list` and `std::forward_list`
  - [List](https://submada.github.io/btl/btl/list/List.html) sequence container - bidirectional linked list.
  - [ForwardList](https://submada.github.io/btl/btl/list/ForwardList.html) sequence container - single linked list.

## Documentation
https://submada.github.io/btl

## History
This repository was in past divided into 3 repositories: **`autoptr`**, **`small-vector`** and **`basic-string`** but they shared many internal parts so I unite them under one.
