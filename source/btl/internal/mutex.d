module btl.internal.mutex;   //original source: object.d

import std.traits : isMutable;

version (Windows){
    import core.sys.windows.winbase : CRITICAL_SECTION, DeleteCriticalSection,
        EnterCriticalSection, InitializeCriticalSection, LeaveCriticalSection,
        TryEnterCriticalSection;

    enum supportMutex = true;
}
else version (Posix){
    import core.sys.posix.pthread;

    enum supportMutex = true;
}
else{
    enum supportMutex = false;
}





public static auto getMutex(Ptr)(scope ref shared Ptr ptr)nothrow @trusted @nogc
out(ret; ret !is null){

    static assert(supportMutex, "this platform doesn't support mutexes");

    //assert(smartPtrMutexes[$-1].isInitialized, "mutexes are not initialized, call `autoptr_initialize_mutexes` to init mutexes.");
    auto m = &smartPtrMutexes[(cast(size_t)&ptr) & (smartPtrMutexes.length - 1)];
    return m;
}

static if(supportMutex){

    //import core.sync.mutex;
    private __gshared shared(Mutex)[16] smartPtrMutexes;

    version(D_BetterC)
        pragma(crt_constructor)extern(C)void shared_static_this()nothrow @nogc{
            autoptr_initialize_mutexes_impl();
        }
    else
        shared static this()nothrow @nogc{
            autoptr_initialize_mutexes_impl();
        }

    private void autoptr_initialize_mutexes_impl()nothrow @nogc{
        foreach(ref shared Mutex mx;  smartPtrMutexes[])
            mx.initialize();
    }

    private struct Mutex{

        public @disable this(ref const typeof(this))pure nothrow @safe @nogc;

        public @disable this(ref shared const typeof(this))shared pure nothrow @safe @nogc;

        public void opPostMove(From, this This)(ref From from){
            assert(0, "no impl");
        }

        public this(this Q)(typeof(null)) @trusted nothrow @nogc
        if(isMutable!Q && supportMutex){
            this.initialize();
        }

        /+public bool isInitialized(this This)()const pure nothrow @nogc @trusted{
            return (m_hndl == typeof(m_hndl).init);
        }+/

        public void initialize(this Q)() @trusted nothrow @nogc
        if(isMutable!Q && supportMutex){
            //assert(!this.isInitialized, "mutexes are already initialized.");

            version (Windows){
                InitializeCriticalSection(cast(CRITICAL_SECTION*) &m_hndl);
            }
            else version (Posix){
                import core.internal.abort : abort;
                pthread_mutexattr_t attr = void;

                if(pthread_mutexattr_init(&attr))
                    abort("Error: pthread_mutexattr_init failed.");
                /+!pthread_mutexattr_init(&attr) ||
                    abort("Error: pthread_mutexattr_init failed.");+/

                scope (exit) if(pthread_mutexattr_destroy(&attr))
                    abort("Error: pthread_mutexattr_destroy failed.");
                /+scope (exit) !pthread_mutexattr_destroy(&attr) ||
                    abort("Error: pthread_mutexattr_destroy failed.");+/

                if(pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE))
                    abort("Error: pthread_mutexattr_settype failed.");
                /+!pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE) ||
                    abort("Error: pthread_mutexattr_settype failed.");+/

                if(pthread_mutex_init(cast(pthread_mutex_t*) &m_hndl, &attr))
                    abort("Error: pthread_mutex_init failed.");
                /+!pthread_mutex_init(cast(pthread_mutex_t*) &m_hndl, &attr) ||
                    abort("Error: pthread_mutex_init failed.");+/
            }
            else static assert(0, "no impl");
        }

        public ~this() @trusted nothrow @nogc{
            version (Windows){
                DeleteCriticalSection(&m_hndl);
            }
            else version (Posix){
                import core.internal.abort : abort;
                if(pthread_mutex_destroy(&m_hndl))
                    assert(0, "Error: pthread_mutex_destroy failed.");
                /+!pthread_mutex_destroy(&m_hndl) ||
                    abort("Error: pthread_mutex_destroy failed.");+/
            }
            //else static assert(0, "no impl");
        }

        /*
         * If this lock is not already held by the caller, the lock is acquired,
         * then the internal counter is incremented by one.
         *
         * Note:
         *    `Mutex.lock` does not throw, but a class derived from Mutex can throw.
         *    Use `lock_nothrow` in `nothrow @nogc` code.
         */
        public void lock(this Q)() nothrow @trusted @nogc
        if(isMutable!Q && supportMutex){
            version (Windows){
                EnterCriticalSection(&m_hndl);
            }
            else version (Posix){
                if (pthread_mutex_lock(&m_hndl) == 0)
                    return;

                import core.internal.abort : abort;
                //abort("Unable to lock mutex.");
                assert(0, "Unable to lock mutex.");
                /+SyncError syncErr = cast(SyncError) cast(void*) typeid(SyncError).initializer;
                syncErr.msg = "Unable to lock mutex.";
                throw syncErr;+/
            }
            else static assert(0, "no impl");
        }

        /*
         * Decrements the internal lock count by one.  If this brings the count to
         * zero, the lock is released.
         *
         * Note:
         *    `Mutex.unlock` does not throw, but a class derived from Mutex can throw.
         *    Use `unlock_nothrow` in `nothrow @nogc` code.
         */
        public void unlock(this Q)()nothrow @trusted @nogc
        if(isMutable!Q && supportMutex){
            version (Windows){
                LeaveCriticalSection(&m_hndl);
            }
            else version (Posix){
                if (pthread_mutex_unlock(&m_hndl) == 0)
                    return;

                import core.internal.abort : abort;
                //abort("Unable to unlock mutex.");
                assert(0, "Unable to unlock mutex.");
                /+SyncError syncErr = cast(SyncError) cast(void*) typeid(SyncError).initializer;
                syncErr.msg = "Unable to unlock mutex.";
                throw syncErr;+/
            }
            else static assert(0, "no impl");
        }

        /*
         * If the lock is held by another caller, the method returns.  Otherwise,
         * the lock is acquired if it is not already held, and then the internal
         * counter is incremented by one.
         *
         * Returns:
         *  true if the lock was acquired and false if not.
         *
         * Note:
         *    `Mutex.tryLock` does not throw, but a class derived from Mutex can throw.
         *    Use `tryLock_nothrow` in `nothrow @nogc` code.
         */
        public bool tryLock(this Q)() nothrow @trusted @nogc
        if(isMutable!Q && supportMutex){
            version (Windows){
                return TryEnterCriticalSection(&m_hndl) != 0;
            }
            else version (Posix){
                return pthread_mutex_trylock(&m_hndl) == 0;
            }
            else static assert(0, "no impl");
        }



        version (Windows){
            private CRITICAL_SECTION    m_hndl;
        }
        else version (Posix){
            private pthread_mutex_t     m_hndl;
        }
        //else static assert(0, "no impl");
    }
}
