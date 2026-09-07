------------------------------------------------------------------------------
--  Iour.Ffi.Fiber.Target body -- the two loops, written once.
------------------------------------------------------------------------------

package body Iour.Ffi.Fiber.Target with SPARK_Mode => On is

   package Txt renames Iour.Ffi.Fiber.Text;

   procedure Model_Switch (S : in out F.State) is
      Entry_Live : constant F.Frame := S.Live;
      Entry_In   : constant F.Frame := S.In_Ctx;

      --  The state before the call being checked.  Ghost, so it costs
      --  nothing; it exists so the obligation can be stated as a relation
      --  between two states rather than with 'Old, which is what makes it
      --  expressible in the interface at all.
      Before : F.State with Ghost;
   begin
      --  Save phase: every location, in ascending offset order.  Coverage
      --  is by construction -- this is a loop over the type -- so there is
      --  no "did we remember this one" obligation to discharge, only the
      --  non-interference one Save_One carries.
      for L in Location loop
         Before := S;
         Save_One (S, L);

         --  The target's side of the interface, checked at the point of
         --  use.  Everything below is proved from this, not from the
         --  actual's own postcondition.
         pragma Assert (Save_Obligation (Before, S, L));

         pragma Loop_Invariant (S.Live = Entry_Live);
         pragma Loop_Invariant (S.In_Ctx = Entry_In);
         pragma Loop_Invariant
           (for all M in Location'First .. L =>
              S.Out_Ctx (M) =
                (if M = Location'First then Resume_Address
                 else Entry_Live (M)));
      end loop;

      pragma Assert
        (for all M in Location =>
           S.Out_Ctx (M) =
             (if M = Location'First then Resume_Address else Entry_Live (M)));

      --  Restore phase: every restorable location, in descending order.
      --  The order is the assembly's, and on both targets so far it is
      --  free: the register holding the incoming context is not itself a
      --  location, so no load can destroy the base the next load needs.
      --  A target where that is false would have to restore that one last.
      for L in reverse Restorable loop
         Before := S;
         Load_One (S, L);
         pragma Assert (Load_Obligation (Before, S, L));
         pragma Loop_Invariant (S.In_Ctx = Entry_In);
         pragma Loop_Invariant
           (for all M in Location =>
              S.Out_Ctx (M) =
                (if M = Location'First then Resume_Address
                 else Entry_Live (M)));
         pragma Loop_Invariant
           (for all M in L .. Restorable'Last => S.Live (M) = Entry_In (M));
      end loop;
   end Model_Switch;

   procedure Check_Switch_Text
     (Text    : String;
      Ok      : out Boolean;
      At_Char : out Natural)
   is
      Cur : Positive := 1;
   begin
      Ok := True;

      for L in Location loop
         Emit_Save (Text, Cur, Ok, L);
         pragma Loop_Invariant (Cur <= Text'Last + 1);
      end loop;

      for L in reverse Restorable loop
         Emit_Load (Text, Cur, Ok, L);
         pragma Loop_Invariant (Cur <= Text'Last + 1);
      end loop;

      Emit_Tail (Text, Cur, Ok);

      if Ok and then not Txt.Consumed_All (Text, Cur) then
         Ok := False;
      end if;
      At_Char := (if Ok then 0 else Cur);
   end Check_Switch_Text;

end Iour.Ffi.Fiber.Target;
