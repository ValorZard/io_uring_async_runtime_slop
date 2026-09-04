package body Iour.Ffi with
  SPARK_Mode    => On,
  Refined_State => (Kernel => null)
is
   --  Kernel has no Ada constituents: it stands for state the operating
   --  system owns, which the bindings in the child packages read and write
   --  on our behalf.
end Iour.Ffi;
