module btl.autoptr.generational_ptr;

import btl.internal.allocator;
import btl.internal.traits;
import btl.internal.gc;

import btl.autoptr.common;


///TODO:
template GenerationalPtr(
    _Type,
    _DestructorType = DestructorType!_Type,
    bool _weakPtr = false
)if(isDestructorType!_DestructorType){

    static if (is(_Type == class) || is(_Type == interface) || is(_Type == struct) || is(_Type == union))
        static assert(!__traits(isNested, _Type),
            "SharedPtr does not support nested types."
        );

    static assert(is(DestructorType!void : _DestructorType),
        _Type.stringof ~ " wrong DestructorType " ~ DestructorType!void.stringof ~
        " : " ~ _DestructorType.stringof
    );

    void check_dtor()(){
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

    enum bool referenceElementType = isClassOrInterface!_Type || isDynamicArray!_Type;

    static if(isDynamicArray!_Type)
        alias ElementDestructorType() = .DestructorType!void;
    else
        alias ElementDestructorType() = .DestructorType!_Type;


    enum bool _isLockFree = false;

    struct GenerationalPtr{

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
        public alias ControlType = ControlBlock!void;


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
            public alias WeakType = GenerationalPtr!(
                _Type,
                _DestructorType,
                true
            );
        else
            public alias WeakType = void;


        /**
            Type of non weak ptr.
        */
        public alias OwningType = GenerationalPtr!(
            _Type,
            _DestructorType,
            false
        );



        /**
            `true` if shared `SharedPtr` has lock free operations `store`, `load`, `exchange`, `compareExchange`, otherwise 'false'
        */
        public alias isLockFree = _isLockFree;



        private ElementReferenceType _element;

        static if(isWeak)
            private size_t _generation;

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
    }
}
