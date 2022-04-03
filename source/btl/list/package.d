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
    alias Node = ListNode!(_Type, _kind);

    enum bool forwardList = (kind == ListKind.Forward || kind == ListKind.Bidirect);
    enum bool backwardList = (kind == ListKind.Backward || kind == ListKind.Bidirect);

    struct List{


        private size_t _length;

        static if(backwardList)
            private Node* _last;
        static if(forwardList)
            private Node* _first;

    }
}
