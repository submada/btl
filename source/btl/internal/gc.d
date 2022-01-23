module btl.internal.gc;



version(D_BetterC){
    public enum bool platformSupportGC = false;
}
else{
    public enum bool platformSupportGC = true;
}




version(D_BetterC){
}
else{
    version(BTL_GC_RANGE_COUNT)
        public __gshared long _conter_gc_ranges = 0;


    version(BTL_GC_RANGE_TRACK)
        package __gshared const(void)[][] _gc_ranges = null;


    shared static ~this(){
        version(BTL_GC_RANGE_COUNT){
            import std.conv;
            if(_conter_gc_ranges != 0)
                assert(0, "BTL_GC_RANGE_COUNT: " ~ _conter_gc_ranges.to!string ~ " != 0");
        }


        version(BTL_GC_RANGE_TRACK){
            foreach(const(void)[] gcr; _gc_ranges)
                assert(gcr.length == 0);
        }
    }
}

//same as GC.addRange but `pure nothrow @trusted @nogc` and with debug testing
public void gcAddRange(T)(const T[] data)pure nothrow @trusted @nogc{
    gcAddRange(data.ptr, data.length * T.sizeof);
}
public void gcAddRange(const void* data, const size_t length)pure nothrow @trusted @nogc{
    version(D_BetterC){
    }
    else{
        import btl.internal.traits;

        assumePure(function void(const void* ptr, const size_t len){
            import core.memory: GC;
            GC.addRange(ptr, len);
        })(data, length);


        assert(data !is null);
        assert(length > 0);

        assumePureNoGc(function void(const void* data, const size_t length)@trusted{
            version(BTL_GC_RANGE_COUNT){
                import core.atomic;
                atomicFetchAdd!(MemoryOrder.raw)(_conter_gc_ranges, 1);
            }



            version(BTL_GC_RANGE_TRACK){
                foreach(const void[] gcr; _gc_ranges){
                    if(gcr.length == 0)
                        continue;

                    const void* gcr_end = (gcr.ptr + gcr.length);
                    assert(!(data <= gcr.ptr && gcr.ptr < (data + length)));
                    assert(!(data < gcr_end && gcr_end <= (data + length)));
                    assert(!(gcr.ptr <= data && (data + length) <= gcr_end));
                }

                foreach(ref const(void)[] gcr; _gc_ranges){
                    if(gcr.length == 0){
                        gcr = data[0 .. length];
                        return;
                    }
                }

                _gc_ranges ~= data[0 .. length];

            }

        })(data, length);
    }
}

//same as GC.removeRange but `pure nothrow @trusted @nogc` and with debug testing
public void gcRemoveRange(T)(const T[] data)pure nothrow @trusted @nogc{
    gcRemoveRange(data.ptr);
}

public void gcRemoveRange(const void* data)pure nothrow @trusted @nogc{
    version(D_BetterC){
    }
    else{
        import btl.internal.traits;

        assumePure(function void(const void* ptr){
            import core.memory: GC;
            GC.removeRange(ptr);
        })(data);

        assert(data !is null);

        assumePure(function void(const void* data)@trusted{
            version(BTL_GC_RANGE_COUNT){
                import core.atomic;
                atomicFetchSub!(MemoryOrder.raw)(_conter_gc_ranges, 1);
            }

            version(BTL_GC_RANGE_TRACK){
                foreach(ref const(void)[] gcr; _gc_ranges){
                    if(gcr.ptr is data){
                        gcr = null;
                        return;
                    }
                    const void* gcr_end = (gcr.ptr + gcr.length);
                    assert(!(gcr.ptr <= data && data < gcr_end));
                }

                assert(0, "BTL_GC_RANGE_TRACK: missing gc range");
            }
        })(data);
    }
}
