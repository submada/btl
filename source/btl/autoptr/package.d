/**
    Imports all modules.

    `btl.autoptr.shared_ptr` : `btl.autoptr.shared_ptr.SharedPtr`

    `btl.autoptr.rc_ptr` : `btl.autoptr.rc_ptr.RcPtr`

    `btl.autoptr.intrusive_ptr` : `btl.autoptr.intrusive_ptr.IntrusivePtr`

    `btl.autoptr.unique_ptr` : `btl.autoptr.unique_ptr.UniquePtr`

    `btl.autoptr.common`
*/
module btl.autoptr;

public{
    import btl.autoptr.common;
    import btl.autoptr.shared_ptr;
    import btl.autoptr.intrusive_ptr;
    import btl.autoptr.rc_ptr;
    import btl.autoptr.unique_ptr;
}
