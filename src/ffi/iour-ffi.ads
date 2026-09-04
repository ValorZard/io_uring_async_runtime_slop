------------------------------------------------------------------------------
--  Iour.Ffi -- bindings to the three C shims under src/c.
--
--  The shims exist for reasons that are not negotiable rather than for
--  convenience:
--
--    * iour_fiber -- saving and restoring a machine context cannot be
--      written in Ada at all.
--    * iour_uring -- nearly all of liburing's API is `static inline`, so
--      those entry points have no symbols to bind to.
--    * iour_net -- socket setup depends on struct sockaddr_in's layout,
--      which is better read from the platform's headers than mirrored.
--
--  No scheduling, buffering, or retry policy lives on the C side.  Every
--  such decision is made in SPARK Ada.
--
--  Every binding takes and returns addresses or scalars, never access
--  values, so the Ada runtime above stays free of pointer types.
------------------------------------------------------------------------------

with Interfaces.C;

package Iour.Ffi with SPARK_Mode => On is

   subtype C_Int is Interfaces.C.int;
   subtype C_Long is Interfaces.C.long;
   subtype C_Unsigned is Interfaces.C.unsigned;
   subtype C_Size is Interfaces.C.size_t;
   subtype C_Uint64 is Interfaces.Unsigned_64;
   subtype C_Uint32 is Interfaces.Unsigned_32;
   subtype C_Int64 is Interfaces.Integer_64;

end Iour.Ffi;
