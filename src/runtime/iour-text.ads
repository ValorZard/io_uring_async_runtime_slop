------------------------------------------------------------------------------
--  Iour.Text -- Put_Line that does not pin a core.
--
--  Ada.Text_IO writes through C stdio, and a write that blocks inside a
--  fiber blocks the whole shard behind it.  This Put_Line builds the line on
--  the caller's stack and hands it to the ring; the fiber suspends and its
--  core serves other fibers until the write completes.
--
--  Called from anywhere that is not a fiber -- the environment task, or the
--  scheduler itself -- it falls back to a plain blocking write(2), since
--  there is nothing to suspend.  So it is safe to use everywhere, and only
--  does the interesting thing where the interesting thing is possible.
--
--  Lines longer than Max_Line are truncated rather than split.
------------------------------------------------------------------------------

package Iour.Text with SPARK_Mode => On is

   Max_Line : constant := 512;

   procedure Put_Line (Text : String);

   --  Same, to standard error.
   procedure Put_Line_Error (Text : String);

end Iour.Text;
